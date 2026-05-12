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

## Additional findings (2026-05-12 Ghidra round 2)

### `sceSblDriverFinalize` decoded (`FUN_c89b7bf0`)

```c
sceSblDriverFinalize():
  unmap_pages(DAT_ca9e3578)                              // teardown gpuvm context
  free(DAT_ca9e3568, 0x100000)                           // 1 MB workspace buffer
  gbase_unregister_interrupt_handler(0x98)               // ★ IRQ vector 0x98 (152) ★
  cleanup(DAT_ca9e3380)
  destroy_condvar(&DAT_ca9e3558)
  destroy_lock(&DAT_ca9e3538)
  destroy_lock(&DAT_ca9e3518)
  destroy_mutex(&DAT_ca9e34f8)
  destroy_lock(&DAT_ca9e3398)
  final_cleanup()
```

**→ This tells us exactly what `sceSblDriverInitialize` must do (inverse):**

```c
sceSblDriverInitialize():
  init_lock(&DAT_ca9e3398)
  init_mutex(&DAT_ca9e34f8)
  init_lock(&DAT_ca9e3518)
  init_lock(&DAT_ca9e3538)
  init_condvar(&DAT_ca9e3558)
  setup(&DAT_ca9e3380)
  DAT_ca9e3568 = kmem_alloc_contig(0x100000, ...)        // 1 MB buffer
  gbase_register_interrupt_handler(0x98, sbl_irq_fn)     // ★ IRQ 0x98 ★
  map_pages(DAT_ca9e3568, ..., &DAT_ca9e3578)            // pin workspace to GPU
```

### `SceSblMsgTask` kthread main (`FUN_c89bb300`)

Decoded the async CCP message dispatch loop. Notable:

- **Thread priority 0x44, stack 0x200 KB (512 KB)**
- Suspend/resume hooks: `system_suspend_phase2_post_sync` and `system_resume_phase2`
- **Ring buffer at `0xca9efc80`, 64 entries × 0xa8 bytes** = 10.5 KB ring
- Index modulo 0x3F (= 64 slots)
- Dispatches by op-type:
  - case `0x09`: notify type 9
  - case `0x02`: notify type 2
  - case `0x00`: notify type 0
- Calls completion callback after copying response

This is the **CCP (Crypto CoProcessor) async path** — needed for crypto offload, **not needed** for Phase 3 (GFX clocks). The simpler synchronous SMU read/write path is enough.

### Confirmed two paths into SAMU

| Path | Sync? | Use case | Where |
|---|---|---|---|
| SMU read/write | synchronous | clock/voltage/PG | `sceSblDriverReadSmuIx/WriteSmuIx` @ `c89b80b0`/`c89b81d0` |
| CCP message queue | async, kthread | hardware crypto | `SceSblMsgTask` @ `c89bb300` |

**For Phase 3 (GFX clocks → fix Hyprland) we only need the synchronous path.** The CCP queue is Phase 4+ territory.

### Critical addresses now confirmed

| Symbol | Address | What |
|---|---|---|
| `sceSblDriverFinalize` | `c89b7bf0` | Teardown — tells us what Init must do |
| `sceSblDriverInitializeResume` | `c89b8770` | Re-init after suspend |
| `SceSblMsgTask` setup | `c89bb260` | Spawns the kthread |
| `SceSblMsgTask` main loop | `c89bb300` | The kthread itself |
| `sceSblDriverReadSmuIx` | `c89b80b0` | ✅ decoded synchronous |
| `sceSblDriverWriteSmuIx` | `c89b81d0` | ✅ decoded synchronous |
| `extractCpuAddrUser` | `c89b6550` | Page-pinning helper |
| **SAMU IRQ vector** | **`0x98`** | gbase_register_interrupt_handler |

### `sceSblDriverInitialize` = `FUN_c89b7380` ✅ DECODED (2026-05-12 round 3)

Full sequence:

```c
sceSblDriverInitialize():
    FUN_c89b64f0()                                   // pre-init
    bzero(&DAT_ca9e33c0, 0x138)                      // clear state struct
    
    // 5 sync primitives:
    mtx_init(&DAT_ca9e34f8, "SblDrvInHdlrMtx", 0, 1)
    sx_init (&DAT_ca9e3398, "SblDrvHdlrSx", 0)       // handler sx-lock
    sx_init (&DAT_ca9e3518, "SblDrvSendSx", 0)       // send-cmd sx-lock
    sx_init (&DAT_ca9e3538, "SblDrvNextSx", 0)       // next-cmd sx-lock
    cv_init (&DAT_ca9e3558, "SblDrvNextCv")          // next-cmd condvar
    
    // 1 MB DMA-coherent buffer below 8 GB, 1 MB aligned:
    workspace = kmem_alloc_contig(0x100000, ..., 0x200000000, 0x100000, 0)
    DAT_ca9e3388 = workspace + 0xc0000               // some scratch pointer
    
    // Pin workspace to GPU virtual address space:
    sceSblDriverMapPages(&DAT_ca9e3570, workspace,
                         0x40, 0x61, 0, &DAT_ca9e3578)
    // count=0x40 (= 64 pages * 16 KB = 1 MB)
    // flags=0x61 = VALID(1) | READABLE(0x20) | WRITEABLE(0x40)
    
    // Start taskqueue for deferred work:
    DAT_ca9e3380 = taskqueue_create("SblDrvTskQ", 1, ...)
    taskqueue_start_threads(&DAT_ca9e3380, 1, 0x3f, "sbldrvtaskq")
    
    // Store async-handler stub:
    DAT_ca9e3590 = FUN_c89b7680  // message dispatch callback
    DAT_ca9e3598 = workspace
    
    // Register SAMU IRQ handler:
    gbase_register_interrupt_handler(0x98, FUN_c89b78c0, 0)
    //                                ^IRQ  ^top-half     ^ctx
    
    // Set up another handler:
    sx_xlock(&DAT_ca9e3398)
    DAT_ca9e3438 = 5
    DAT_ca9e3440 = FUN_c89b7a60  // another callback
    DAT_ca9e3448 = 0
    sx_xunlock(&DAT_ca9e3398)
    
    DAT_ca9e35a0 = workspace_gpu_va | 0x100000000000000
    FUN_c89b7af0()
    
    bzero(&DAT_ca9e35b0, 0x180)
    return 0
```

**For our Linux port (Phase 1), the minimum init is:**

1. Allocate 1 MB DMA-coherent buffer (use `dma_alloc_coherent` or `pci_alloc_consistent`)
2. Map it into amdgpu's GART via `amdgpu_gart_bind`
3. Init 5 sync primitives (mutex + 3 rwsems + condvar) — or simpler equivalents
4. Skip taskqueue initially (sync SMU read/write doesn't use it)
5. **Skip IRQ registration initially** — we can poll the ack register `0x4a` synchronously

The **minimum** functional Linux SBL driver is therefore:

```c
struct ps4_sbl {
    struct amdgpu_device *adev;       // GPU device
    void __iomem *mmio;               // GPU BAR mapping
    void *workspace_cpu;              // 1 MB buffer
    dma_addr_t workspace_dma;
    u64 workspace_gpu_va;             // after GART bind
    struct mutex send_lock;
};

int ps4_sbl_read_smu(struct ps4_sbl *sbl, u32 idx, u32 *out)
{
    int err;
    mutex_lock(&sbl->send_lock);
    
    writel(0xa404,  sbl->mmio + 0x22070);   // service id = SMU_READ
    writel(idx,     sbl->mmio + 0x22074);
    writel(1,       sbl->mmio + 0x32);      // trigger interrupt
    
    while (readl(sbl->mmio + 0x4a) & 1)
        cpu_relax();                        // poll for ack
    
    err = readl(sbl->mmio + 0x2207c);       // error code
    if (!err)
        *out = readl(sbl->mmio + 0x22078);  // value
    
    mutex_unlock(&sbl->send_lock);
    return err;
}

int ps4_sbl_write_smu(struct ps4_sbl *sbl, u32 idx, u32 val)
{
    int err;
    mutex_lock(&sbl->send_lock);
    
    writel(0xa505,  sbl->mmio + 0x22070);   // service id = SMU_WRITE
    writel(idx,     sbl->mmio + 0x22074);
    writel(val,     sbl->mmio + 0x22078);
    writel(1,       sbl->mmio + 0x32);
    
    while (readl(sbl->mmio + 0x4a) & 1)
        cpu_relax();
    
    err = readl(sbl->mmio + 0x2207c);
    
    mutex_unlock(&sbl->send_lock);
    return err;
}
```

**That's the entire Phase 1 patch in ~70 lines.** Plus init/exit + debugfs entry. We can write this in one iteration once we have the workspace allocation pinned via amdgpu_gart_bind.

### Outstanding (lower priority now)
- **Service ID table** — likely a data table near handler.c functions. Look for byte patterns `0xa404`, `0xa505`, etc. as consecutive entries.
- **SMU indices Sony writes for GFX clocks** — find by:
  - cross-referencing `sceSblDriverWriteSmuIx` callers in `gc/` (gbase code)
  - looking for `WriteSmuIx(0x???????, val)` with constant indices

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
