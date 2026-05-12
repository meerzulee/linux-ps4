# Sony SBL Driver Port — Plan

**Goal:** Port Sony's SAMU mailbox protocol to Linux kernel so amdgpu can program SMU registers (locked from CPU on retail PS4). This is the **root-cause fix** for:

- UVD hardware video decode (currently A18 soft-failed)
- VCE hardware video encode (currently A19 soft-failed)
- GFX ring hangs under load (currently blocking Hyprland / GL-rendered Wayland)
- HDCP-protected video paths
- Probably display power-management (sleep / wake)

If we crack this, the whole AMD GPU stack works properly on PS4 Linux.

---

## What we already have (from dungeon mapping)

From `checkpoint/docs/research/orbis-dungeon/rooms/sbl-driver.md`:

```c
// already decoded
sceSblDriverReadSmuIx(smu_index, &out_value):           /* FUN_c89b80b0 */
    samu_write(0x22070, 0xa404)         /* SBL read-SMU service id */
    samu_write(0x22074, smu_index)
    samu_write(0x32, 1)                 /* trigger interrupt to SBL */
    while (samu_read(0x4a) & 1):        /* poll until SBL acks */
        block_on_signal()
    err = samu_read(0x2207c)
    if (!err): *out_value = samu_read(0x22078)
    return err

sceSblDriverWriteSmuIx(smu_index, value):               /* FUN_c89b81d0 */
    samu_write(0x22070, 0xa505)
    samu_write(0x22074, smu_index)
    samu_write(0x22078, value)
    samu_write(0x32, 1)
    while (samu_read(0x4a) & 1): block_on_signal()
    return samu_read(0x2207c)
```

Where `samu_write/read` map to GPU mmio offsets `0x22070..0x2207c` (which is in the SAMU mailbox region) plus interrupt register `0x32` and ack register `0x4a`.

**Service IDs we know:**

| Code | Service |
|---|---|
| `0xa404` | SBL_SMU_READ |
| `0xa505` | SBL_SMU_WRITE |

The rest of the service ID table needs to be reverse-engineered from `handler.c` (FUN_c89b6550 onwards).

---

## What we're missing

1. **Initialization sequence.** The SAMU may need to be in a specific state when we first send a command. Sony does this at boot via `sceSblDriverInitialize`. We need to either replicate or detect that init has already happened.

2. **Service-handler registration.** Linux-side code needs to listen for async messages from the SAMU (`SceSblMsgTask` thread in Sony). We'll need a workqueue or kthread doing equivalent work.

3. **Page-pinning protocol.** `sceSblDriverMapPages` lets SAMU access kernel buffers. Some SMU commands probably need a buffer pointer. Format unknown.

4. **Authentication tokens.** Sony's SAMU may check that the caller is "blessed" — i.e., running from a signed binary. If so, we need to find how the auth happens or whether PSFree's bypass already covers it.

5. **The actual SMU index that controls GFX clocks.** Sony presumably writes specific SMU indices to set GFX clock / voltage / power-gating. Mainline amdgpu's SMU code for CIK has these constants but they're for unlocked CPUs — Sony might use different indices or values.

---

## Iteration plan (high level)

Each iteration is its own kernel patch + hardware test cycle, similar to UVD A1..A19.

### Phase 1: Mailbox primitives (~3-5 iters)

**P1.1** Locate the SAMU mmio region on Linux side. `0x22070..0x2207c` is GPU BAR offset; we need amdgpu to give us a pointer. Use `amdgpu_device_rreg/wreg` to read/write at those offsets and confirm we get the expected values (or non-zero — anything but all 0xFF).

**P1.2** Implement `sbl_samu_read_smu(idx, &out)` and `sbl_samu_write_smu(idx, val)` matching the Ghidra-decoded sequence. Add a kernel param to enable debug printing of every transaction.

**P1.3** Test: read a known-readable SMU index. Mainline amdgpu's `cik_smu.h` lists SMU register addresses. Try reading the version register first — should return a non-zero value if SAMU is responsive.

**P1.4** Build a Linux ioctl or debugfs entry to issue test reads/writes from userspace. Lets us probe SMU indices without recompiling.

**P1.5** If reads work but writes don't: probably authentication. Investigate.

### Phase 2: Inbound message handling (~2-3 iters)

**P2.1** Find SAMU's interrupt vector. Sony's IH delivers SAMU messages via an interrupt; we need to either hook the same IH source or poll.

**P2.2** Implement `sbl_register_msg_handler(svc_id, fn)` — a callback table mapped by service ID.

**P2.3** Implement a Linux equivalent of `SceSblMsgTask` — kthread or workqueue that reads pending messages and dispatches to handlers.

### Phase 3: GFX clock programming (~3-5 iters)

**P3.1** Identify the SMU indices that control:
  - GFX engine clock (mmCG_SPLL_*)
  - GFX voltage
  - GFX power-gating enable/disable

**P3.2** Add a kernel function that programs these. amdgpu calls it from `amdgpu_dpm_set_*` paths.

**P3.3** Test: with our SMU writes, can we lock GFX at a sane clock (e.g. 200 MHz minimum)? Does the GFX ring no longer hang?

**P3.4** If yes: try Hyprland again. Expect either success or a different failure.

### Phase 4: UVD / VCE / HDCP (~2-3 iters)

**P4.1** Find the SMU/SBL commands Sony uses for UVD pre-init.

**P4.2** Wire up so that `uvd_v4_2_start_liverpool` calls our SBL driver before VCPU release.

**P4.3** Hardware test — should be where A18 fails. With proper SMU setup, STATUS bit 1 might fire.

**P4.4** Same for VCE.

### Phase 5: Stability / Linux upstream (~unbounded)

- Make the driver upstream-quality
- Documentation
- Match mainline coding style (probably gets rejected upstream for being PS4-specific, but worth keeping clean)

---

## First concrete iteration: P1.1 + P1.2

Smallest viable test: add a kernel module / patch that:

1. Maps the GPU BAR mmio range that contains SAMU mailbox (`0x22070..0x2207c`, `0x32`, `0x4a` in GPU regs).
2. Provides `sbl_read_smu(idx)` and `sbl_write_smu(idx, val)` C functions.
3. Adds a debugfs entry `/sys/kernel/debug/dri/0/ps4_sbl_smu_read` and `_write` to probe from userspace.
4. Prints every transaction via DRM_INFO so we can see what's happening.

Then via SSH:
```bash
# Read SMU version register (index TBD, probably 0xC0080000 or similar from CIK headers)
echo 0xC0080000 > /sys/kernel/debug/dri/0/ps4_sbl_smu_read
cat /sys/kernel/debug/dri/0/ps4_sbl_smu_read  # should show the read value
```

If the read returns sensible bytes: SAMU is talking to us, Phase 1 works.

If the read hangs forever (mailbox never acks): SAMU is locked / not initialized / requires auth.

If the read returns garbage: encoding wrong, retry with different format.

---

## Estimate vs reality

I said "weeks-months" earlier. Realistic breakdown:
- Phase 1: 1-2 weeks (mailbox basics)
- Phase 2: 1 week (inbound IRQ)
- Phase 3: 2-3 weeks (SMU programming — depends on how many indices need RE)
- Phase 4: 1-2 weeks (UVD/VCE wire-up — most groundwork done in dungeon)
- Phase 5: ongoing

**Total optimistic:** 6-10 weeks of iteration cycles.

Could be faster if we get lucky on auth (Sony may not require auth from kernel ring 0, since the original boot loader runs at ring 0 too).

Could be slower if Sony's SAMU rejects our commands and we have to investigate the rejection mechanism.

---

## Open questions

1. Does PSFree-Enhanced compromise enough to talk to SAMU? Pretty sure yes (we have FreeBSD ring 0) but never tested.
2. Does the SAMU require the caller to have specific SoC privileges (like Sony's kernel does via ATOM BIOS roots)? Unknown.
3. Are there working PS4 reverse-engineering communities that have already documented SMU commands? Probably yes (fail0verflow, OpenOrbis, etc.). Worth checking before deep RE.

---

## Next steps if we commit to A

1. Verify FTP/SSH access works on PS4 (currently testing — gives us iteration loop)
2. Set up a feature branch `wip/sbl-port` separate from current `wip/uvd-vce-poc`
3. Start with P1.1: small read-from-SAMU experiment
4. After each iteration, update this PLAN.md with what we learned

For now, **Option C (PM disable bootargs)** is staged. Once PS4 reboots we'll know if it makes Hyprland survive.
