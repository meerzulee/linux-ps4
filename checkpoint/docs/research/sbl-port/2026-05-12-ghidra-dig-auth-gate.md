# 2026-05-12 — Ghidra dig session: SBL auth-gate investigation

Target: figure out WHY Sony's `sceSblDriverWriteSmuIx` succeeds and ours
returns `-EACCES`, by tracing every caller and every prerequisite.

Headline: **the auth check is internal to SAMU's signed firmware**, not in
orbis-12.02.elf. The Linux-side WriteSmuIx is a thin shim that just writes
the mailbox and reads back the status. So the auth gate is whatever SAMU
checks AT WRITE TIME — which we can only probe black-box from the host.

But we found **a lot** of useful structural info that informs what to
probe next.

---

## 1. Full SBL service-ID map (was: 2 services; now: 4)

| Helper (Ghidra addr) | Service ID @ `0x22070` | Purpose | Lock? |
|---|---|---|---|
| `sceSblDriverReadSmuIx` (`c89b80b0`) | `0xa404` | SMU register read | yes |
| `sceSblDriverWriteSmuIx` (`c89b81d0`) | `0xa505` | SMU register write | yes |
| `FUN_c89b85f0` | `0xa505` | SMU write, no-lock variant | no |
| `FUN_c89b8570` | `0xa404` | SMU read, no-lock variant | no |
| `FUN_c89b82f0` | `0xa202` | **NEW**: 2-arg read, returns to *out | yes |
| `FUN_c89b8670` | `0xa202` | same, no-lock | no |
| `FUN_c89b8410` | `0xa303` | **NEW**: 2-arg write | yes |
| `FUN_c89b86f0` | `0xa303` | same, no-lock | no |

Service-ID pairing pattern: `0xaXYZ_w` / `0xa(X+1)(Y+1)(Z+1)_r` — same SBL
opcode family, write/read variant. So:

- `0xa202 (read) / 0xa303 (write)` — some non-SMU register space (possibly
  SAMU-internal regs, GPU "TLB" space, or HDCP key slots)
- `0xa404 (read) / 0xa505 (write)` — the SMU register space we've been
  probing

Our session 3 sweep observed **only 0xa404 returns status=0; 0xa505 returns
−EACCES; everything else returns "unknown service" (−37)**. We need to retest
with the new known service IDs `0xa202` and `0xa303` — they may either also
be auth-gated, or have a different policy.

---

## 2. Service-id-5 callback is `writeHandler`, NOT auth

`FUN_c89b7a60` was registered as the service-id-5 callback in
`sceSblDriverInitialize` (per the round-2 PLAN.md). Decompiled this round:

```c
void writeHandler(msg) {
    if (size_field > 0xfdd) panic("illegal size");
    if (type_field != 2) panic;
    printk("%s", msg + 0x20);     // log the buffer contents
}
```

This handler **receives** SAMU-originated log messages and prints them via
`printk`. NOT a write-auth precursor.

---

## 3. `FUN_c89b7af0` is a SAMU-direct command, not a workspace-only setup

Called at the end of `sceSblDriverInitialize` with `workspace_gpu_va |
0x100000000000000` as the arg. Body:

```c
samu_ind_write(0x34, low32(param_1));
samu_ind_write(0x33, high32(param_1));
samu_ind_write(0x32, 1);                  // kick
poll SAMU[0x4a] until clear
```

So this sends a "set workspace pointer" message **directly through the
indirect SAMU window** (NOT via the `0x22070` mailbox). It's a different
command channel — SAMU has TWO separate command paths:

1. **Direct SAMU-internal command** — write parameters to SAMU regs in the
   indirect window, kick SAMU[0x32]. Used for init/setup at boot.
2. **Mailbox command** — write service id + args to the `0x22070..0x2207c`
   data window, kick SAMU[0x32], read result back from same window.
   Used for runtime SBL service requests.

This dual-channel architecture is new info; PLAN.md missed it.

The workspace pointer we observed (`SAMU[0x34] = 0x1e102000`, `SAMU[0x33] = 0`)
matches: a low 32-bit physical/GPU VA was set during Orbis init and is still
sitting in the SAMU's state slots. So the workspace IS set up — just by
Sony's Orbis, not by Linux. **Re-setting it from Linux is a probe candidate**:
maybe SAMU checks "workspace was set THIS BOOT" or "workspace owner matches
requester".

---

## 4. The async completion machinery (IRQ 0x98 handler)

`FUN_c89b78c0` is the IRQ 0x98 handler installed by `sceSblDriverInitialize`.
Decompiled body:

```c
void samu_irq_handler(void) {
    DAT_ca9e3730 = 1;                  // "IRQ in progress" flag

    irq_status = gpu_reg_read(0x3a9);
    if (irq_status != 0) {
        // log to a 16-slot ring buffer at DAT_ca9e35b0
        ring[i].ints  = irq_status
        ring[i].rder  = gpu_reg_read(0x3a6)
        ring[i].stat  = gpu_reg_read(0x394)
        ring[i].stat2 = gpu_reg_read(0x393)
        ring[i].tsc   = rdtsc()
    }

    if (samu_ind_read(0x4b) & 1) {
        samu_ind_read(0x36);           // ack registers
        samu_ind_read(0x35);
        gbase_dispatch(workspace_msg)  // FUN_c85e3b00
    } else {
        printk("INTS:... RDER:... STAT:... STA2:... tsc:...")
    }
}
```

Key observations:

- **GPU registers `0x3a9` (dword index)** is read by the IRQ handler — that's
  byte `0xEA4`, which lives in the rmmio space. We can read it from
  `amdgpu_regs` to see the current SAMU IRQ status without rebuilding.
- **SAMU[0x4b]** is checked as the "we have a workspace message" flag.
- **SAMU[0x35] / SAMU[0x36]** are read as part of completion — they're
  paired with [0x33]/[0x34] in the indirect register space.
- The Linux waiter (`DAT_ca9e3730`) is set HERE and cleared in
  `FUN_c89b7680` (the dispatch callback). Linux waits between IRQ-set and
  dispatch-clear.

---

## 5. Linux-side dispatcher = `FUN_c89b7680`

The callback invoked from `gbase_dispatch` when SAMU sends a reply message.
Routes by cmd field (`*param_1`), 0..0xc valid. Callback table at
`DAT_ca9e33c0`, indexed `[cmd * 0x18]`. After dispatch:

```c
DAT_ca9e3730 = 0;                       // clear "IRQ busy"
samu_ind_write(0x37, 1);                // SAMU completion ack
cv_broadcast(&condvar);                 // wake any cv_wait'er
```

So SAMU[0x37] is written by Linux to tell the SAMU "I've processed your
reply". **Currently in our system, our writes never get a reply** (synchronous
−EACCES, no IRQ generated → SAMU doesn't put anything in the workspace).

Hypothesis worth testing: maybe SAMU requires Linux to have IRQ 0x98
registered AND for some "ready" bit to be set before writes succeed.
We can fake the ready bit by writing `SAMU[0x37] = 1` before our write.

---

## 6. **Treasure**: the GFX clock-set function (`FUN_c8856160`)

This is the **canonical Sony GFX clock programming routine**. Body:

```c
void gfx_set_clock(int MHz) {
    uint divider = (MHz * 0x28f5c3) >> 10;     // MHz → SMU divider
    if (divider == DAT_c9e3199c) return;       // cached, no change

    WriteSmuIx(0xC05002E4, divider);
    WriteSmuIx(0xC05002B4, 0x100);
    WriteSmuIx(0xC05002DC, 0x14009);
    WriteSmuIx(0xC05002B0, 0x19);
    WriteSmuIx(0xC05002C0, 0x08000082);
    WriteSmuIx(0xC05002C4, 0x64000000);
    WriteSmuIx(0xC05002AC, 0x60840000);        // PLL toggle 1
    // poll ReadSmuIx(0xC05002E0) until bit 2 set, max 98 iters
    WriteSmuIx(0xC05002AC, 0x40840000);        // PLL toggle 2
    // poll ReadSmuIx(0xC05002E0) until bit 2 set
    DAT_c9e3199c = divider;
}
```

Error strings: `"GCK_FGPLL_spllcntl1 0: 0x%x spllcntl2:0x%x"` — confirms
this is the GFX FGPLL (frequency PLL) cntl/divider write sequence.

**This is exactly the function we'd want amdgpu's UVD/VCE init to call**
before bringing up the engines. The whole UVD bring-up failure (A-arc) was
because the VCPU is waiting on clocks Sony's gbase normally sets here.

Caveat: this routine uses the locked `sceSblDriverWriteSmuIx` (`c89b81d0`),
the very one returning −EACCES for us. So we need to crack auth before we
can call this from Linux.

Also notably: `0xC05002E4` etc are NOT what mainline AMD CIK SMC headers
name these as. **Sony has a custom SMC firmware** with its own register
layout in the 0xC0500000 bank. The values written here (`0x14009`,
`0x60840000`, etc) are PLL programming constants specific to Sony's SMC.

---

## 7. Caller count for WriteSmuIx (the auth-gated path)

`get_xrefs_to(c89b81d0)` returned **34 callers** across `gc/` (gbase) and
`gpu/` code paths. They cluster into:

- Clock-set group: `FUN_c8856160` (GFX), `FUN_c88562e0`, `FUN_c8857780`,
  `FUN_c8857020` (4 writes per call — could be 4-pll-divider sequence),
  `FUN_c8855fd0` (single write — maybe voltage),
  `FUN_c8855a30` (heavy caller, 6+ writes per invocation — full PG setup?)
- Power management group: `FUN_c8850f90`, `FUN_c8850fe0`, `FUN_c88512d0`,
  `FUN_c8851560`, `FUN_c88517f0`, `FUN_c8851a40`, `FUN_c8851b00`,
  `FUN_c8851d90` (paired write/poll structure typical of P-state changes)
- Misc: `FUN_c8a7fb60` (one call only — possibly UVD-specific?)

Decompiling 2-3 of the cluster heads (`FUN_c8855a30`, `FUN_c8851d90`,
`FUN_c8857020`) would give us the **full P-state and power-gating table** that
mainline AMD CIK powerplay code lacks for Liverpool. **Even without auth
bypass, just knowing the values Sony writes is valuable** — could be applied
via a different mechanism (e.g., direct SMC ROM patching at boot, if/when
feasible).

---

## 8. Probe candidates for the next reboot

All testable via the existing `/sys/kernel/debug/dri/0/amdgpu_regs` surface
(no kernel build needed). These probes will check specific auth-bypass
hypotheses:

### A. New service IDs

Try `0xa202` (read) and `0xa303` (write):
```
echo 'P 0xa202 0x10' ... // see what register space 0xa202 reads
echo 'P 0xa303 0x10 0xcafe' ... // see if 0xa303 writes are also gated
```

If `0xa303` returns status=0 (no auth), there's a write-capable service we
missed. If it also returns −EACCES, the gate is on writes-in-general, not
on the specific service ID.

### B. Re-setup the workspace pointer

```
SAMU[0x34] = (some valid GTT-bound address)
SAMU[0x33] = 0
SAMU[0x32] = 1                     // kick
// poll SAMU[0x4a]
```

Then try a write. If `-EACCES` goes away → SAMU was rejecting because
workspace was stale/orphaned from Orbis. If still `-EACCES` → workspace isn't
the gate.

### C. Try the SAMU[0x37] ack-ack

Write `SAMU[0x37] = 1` (which Linux's dispatcher does after processing a
reply). Maybe SAMU treats this as "ready to receive more". Then try a write.

### D. Read SAMU's IRQ status reg via rmmio direct

`amdgpu_regs` byte offset for `gpu_reg_read(0x3a9)` = dword 0x3a9 = byte
0xEA4. Read it before/after probes to see SAMU IRQ activity.

### E. Pattern hunt in SAMU regs around 0x4b

We swept 0x00..0x80. Let me run a finer probe at 0x4b..0x60 + look for any
state that toggles. Especially around 0x35, 0x36, 0x37 which all surfaced
in this dig.

---

## 9. If A–E all fail to bypass auth

We've explored the readable state. If none of the above un-gates writes, the
SAMU is requiring something only the signed boot chain can produce
(unforgeable). Two non-Ghidra moves remain:

1. **Read-only Phase 3 (mapping)**: just read the entire DPM table at
   `0xC0500000` and document the Sony SMC's runtime configuration. We can
   read the values Sony's gbase writes (via the function decompiles in
   §7), so we have a complete picture of "what state would be" if we could
   write.

2. **sceUbios path**: the partial sceUbios runtime we have references
   `sceUbiosWriteSmuRegister` — that runs in the EARLIER boot phase
   (before SAMU lock-down). If we ever get a full sceUbios dump or can run
   anything in that early phase, the auth might not yet be enabled. The
   discord-folder ELF has the header but only ~1% of the binary; a full
   dump would be the next external dependency to get.

---

## 10. Action item summary

Probes to run on next boot (testable now since we have FTP path back):

- [ ] `0xa202` read sweep — what register space does the OTHER read service expose?
- [ ] `0xa303` write attempt — same auth gate, or different?
- [ ] Re-write workspace pointer at `SAMU[0x33-0x34]` then try `0xa505`
- [ ] Write `SAMU[0x37] = 1` then try `0xa505`
- [ ] Read GPU IH status reg `byte 0xEA4` (= dword `0x3a9`) before/after a `0xa505` attempt
- [ ] Decompile `FUN_c8855a30` (heaviest WriteSmuIx caller) to extract the full PG sequence
- [ ] Decompile `FUN_c8857020` (4-write pattern, looks like P-state index set) for power state table
- [ ] If time: decompile `FUN_c8a7fb60` (single isolated WriteSmuIx caller, possibly UVD-specific)
