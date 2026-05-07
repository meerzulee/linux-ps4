# 07 — Why 6.x hangs, and what to do about it

This is the working theory document — what we know about the 6.x
late-init hang, ranked hypotheses, and the experiments that would
distinguish between them. Update as new data comes in.

## What we observe

- **Build is clean**. 6.15.4 + 13 patches compiles with GCC 15. 9.3MB
  bzImage produced reliably. Kernel string:
  `6.15.4-Baikal_TESTING_crashniels-dirty`.
- **kexec handoff works**. From a running 5.4 over SSH, `kexec -l`
  + `systemctl kexec` successfully transitions. SSH drops cleanly.
- **Earlycon comes up**. ~120 lines of UART output via earlycon at
  `0xC890E000`, covering decompression → BIOS-e820 → ACPI → CPU
  bring-up → memory init → IRQ alloc.
- **Hang point**: somewhere around fbcon takeover (~0.66s into
  kernel time). UART goes silent (this is expected — earlycon
  retires when `console=tty0` registers). HDMI goes black or shows
  no useful output. SSH never comes up.
- **Mouse/keyboard non-functional**. USB devices don't appear to be
  responsive after the hang.
- **`init=/bin/sh` + GPU blacklist + `nofb` still hangs**. Tested
  2026-05-07. Tells us the hang is **not** in userspace and **not**
  exclusively in fbcon takeover or graphics drivers.
- **`bpcie-uart` `port.type` fix triple-faults at kexec on 6.x**.
  Same patch works fine on 5.4. Currently disabled in 6.x series.

## What we DON'T know yet

- The last kernel message printed before the hang (UART silenced
  too early to capture; we'd need a photo of HDMI fbcon at hang
  time, or the patch series applied with `keep_bootcon` even though
  it's risky).
- Whether the hang reproduces on **crashniels' tree built as-is**
  (no patch-slicing on our part).
- Whether IOMMU is the variable: `iommu=off amd_iommu=off` cmdline
  hasn't been tried.
- Whether GCC 15 produces something different from crashniels'
  toolchain.

## Hypotheses, ranked

### Tier 1 — most likely (50%+ probability)

#### H1. MSI / IRQ-domain plumbing is wrong on Baikal

**Why suspect**: `patches/6.x-baikal/1100-pci-msi/0001-...` is the
single most rewritten patch in the 6.x series. It introduces
`x86_fwspec_is_aeolia()`, exposes new symbols
(`x86_vector_msi_compose_msg`, `pci_msi_domain_write_msg`), and
modifies `arch_dynirq_lower_bound()`. The IOMMU patch (1000) has
a leftover `pr_err("Remapping Selected: %x\n")` which strongly
suggests this patch was actively under development when crashniels
published. If the predicate misfires for Baikal — for instance,
if the device-tree spec it checks is Aeolia-only and Baikal needs
its own — then **MSI delivery silently fails for downstream
devices**. xHCI, AHCI, sky2 would all hang at probe waiting for
IRQs that never arrive.

**Symptom match**: hangs at fbcon-time-ish, no SSH, no USB
input. Devices not coming up matches "MSI not delivered".

**Diagnostic**: cmdline `iommu=off amd_iommu=off`. If 6.x boots,
H1 confirmed. Cost: 1 chain.

**Fix path**: read 6.x patch carefully, compare `x86_fwspec_is_aeolia()`
implementation against what Baikal actually exposes via IRQ
firmware spec. May need to extend it to recognize Baikal as well as
Aeolia (or rename to `x86_fwspec_is_ps4_southbridge()`).

#### H2. Liverpool DRM bridge stuck in modeset

**Why suspect**: DRM is one of the most-changed subsystems in
mainline. The 0300 patches port the bridge, but it's complex code.
"Hangs at fbcon takeover" is **textbook** stuck-modeset symptom —
DRM is waiting for a vblank or HPD event that never fires.

**Symptom match**: fbcon takeover is exactly when DRM tries to
take over the framebuffer; if `ps4_bridge_attach()` hangs, this is
where you'd see the kernel freeze.

**Counter-evidence**: `init=/bin/sh modprobe.blacklist=radeon,amdgpu nofb`
still hangs. With those drivers blacklisted and `nofb`, DRM
shouldn't be doing modeset at all. So either the blacklist isn't
working (worth verifying — modprobe.blacklist is parsed by
userspace, not the kernel, and both drivers may be `=y` in our
config), or the hang isn't in DRM.

**Action**: check 6.x config — is `CONFIG_DRM_RADEON=y` or `=m`?
If `=y`, modprobe.blacklist won't help; need a Kconfig rebuild
with `CONFIG_DRM_RADEON=n`.

**Diagnostic**: Kconfig disable + rebuild. Cost: 1 chain. (Build
time ~3 min, plus the chain to test.)

### Tier 2 — possible (20–40%)

#### H3. AHCI / sky2 / xHCI device probe hangs due to DMA mask change

**Why suspect**: DMA mask API changed substantially between 5.4
and 6.x. `dma_set_mask_and_coherent()` signature differs; the
31-bit hard-coded values in our patches (AHCI, sky2, sdhci) may
not work without modification.

**Symptom match**: would manifest as probe hang, kernel stuck in
device init thread.

**Diagnostic**: `initcall_debug` cmdline + photo of HDMI when
hung. Last `initcall: <function>+0x..` line names the hung
device. Cost: 1 chain, very high information yield.

**Counter-evidence**: this would typically present as a watchdog
warning ("hung_task_timeout"), and we'd see that on UART or HDMI.
We don't. Possibly because watchdog wasn't enabled at hang time.

#### H4. Missing patches

**Why suspect**: we sliced crashniels' tree into 13 patches. If
our slicing dropped any non-obvious file or hunk, the resulting
kernel may be subtly broken.

**Diagnostic**: build crashniels' tree directly (no patch-slicing
through our system), test that. If theirs boots and ours doesn't,
our slicing introduced a bug. Cost: 1 chain.

### Tier 3 — less likely (10–20%)

#### H5. Toolchain regression

**Why suspect**: GCC 15 is recent. crashniels' tree may have been
built with GCC 13 or 14. Code generation differences in ASM-heavy
paths (head_64.S, IRQ vector dispatch) could cause silent
regressions.

**Diagnostic**: build with GCC 14 instead. Cost: 1 chain.

#### H6. ACPI quirk

**Why suspect**: ACPI tables on PS4 are slightly non-standard
(Sony custom firmware). 6.x ACPI parser is stricter than 5.4's.

**Diagnostic**: cmdline `acpi=off` (boot will be very degraded but
should at least show where it gets stuck). Cost: 1 chain.

### Tier 4 — unlikely

#### H7. PSFree / payload / loader interaction with new kernel

**Why suspect**: ArabPixel v24b was tuned against Linux 5.x. 6.x
may have different early-boot expectations.

**Counter-evidence**: kexec from running 5.4 (which doesn't go
through the loader at all) also hangs. So loader is not the
issue.

## Diagnostic experiment plan, by chain cost

### Cheapest first (1 chain each, single test)

1. **`initcall_debug` + photo HDMI** — gives us the exact initcall
   that hung. Highest information per chain. **Run this first.**
2. **`iommu=off amd_iommu=off`** — disambiguates H1.
3. **Rebuild with `CONFIG_DRM_RADEON=n` + `CONFIG_DRM_AMDGPU=n`** —
   disambiguates H2.
4. **Build crashniels' tree as-is** (no slicing) — disambiguates H4.
5. **Build with GCC 14** — disambiguates H5.

### More expensive (multi-chain or multi-build)

6. **Patch bisection** — apply patches one group at a time
   onto vanilla 6.15.4, build each step, find which group's
   addition breaks. ~6 builds × 3min = 18min compile time, plus 1
   chain per build that needs testing. Very informative but
   expensive.
7. **Manual MSI debug** — add `pr_info` lines around
   `x86_fwspec_is_aeolia()` and Baikal MSI dispatch. Rebuild, test,
   read UART. Cost: 1 chain to get useful trace data.

## Order of operations (recommended)

If you have **3 chains** to spend in the next session:

1. **Chain 1**: `initcall_debug` cmdline. Photo HDMI when hangs.
   Identifies the hung initcall.
2. **Chain 2**: based on what initcall #1 named:
   - If GPU initcall → disable DRM_RADEON/AMDGPU, rebuild, test.
   - If something IOMMU/MSI-related → cmdline `iommu=off`.
   - If something else → look it up, target the right experiment.
3. **Chain 3**: validate the fix. If chains 1+2 found the cause,
   chain 3 confirms a working fix.

If you only have **1 chain**: spend it on `initcall_debug`. Without
that, you're guessing. The HDMI photo at hang time is worth a
hundred speculations.

## Things to NOT do yet

- **Don't re-enable `0200/0003-ps4-bpcie-uart-set-port-type.patch`**.
  It triple-faults 6.x at kexec. Unsolved separately from the hang
  problem. Investigate later, after main hang is fixed.
- **Don't use `keep_bootcon`**. Crashes xhci_aeolia at ~57s on 5.4.
  Unknown but probably also bad on 6.x.
- **Don't pacstrap into rootfs**. The current rootfs is deeWaardt's
  Baikal Ed. (v2-baseline). pacstrapping over it from a v3 host
  reintroduces the SIGILL panic.

## When the hang is fixed, the next problems are

1. **mt7668 not ported** — no WiFi on 6.x. Either rebuild against
   ethernet (sky2 currently broken on Baikal too — would need
   fixing first) or port mt7668 forward from 5.4.
2. **Real ttyS transmit** — even on 5.4, ttyS4 doesn't actually
   transmit despite the port.type fix. Fix the FIFO setup or
   driver state machine.
3. **6.x bpcie-uart port.type fix** — figure out why it
   triple-faults at kexec. Likely `UPF_FIXED_TYPE` semantics
   changed.

## Updating this document

When you run an experiment, append the result here. Format:

```
### YYYY-MM-DD — experiment name
- Cmdline / config / build details
- Outcome: boots / hangs at X / kexec triple-fault
- What this tells us: ...
- Updated hypothesis ranks: ...
```

Done so far:

### 2026-05-07 morning — `init=/bin/sh modprobe.blacklist=radeon,amdgpu nofb` (kexec from 5.4)

- Cmdline included full earlycon from the running 5.4 plus the extras.
- initrd: `checkpoint/boot/initramfs.cpio.gz` (4.1MB).
- Outcome: kexec handoff succeeded (SSH dropped). 180s SSH timeout
  hit; user reported "died" (no SSH return).
- **Test was inconclusive — blacklist had ZERO effect.** Confirmed
  in `config/6.x-baikal.config`: `CONFIG_DRM_AMDGPU=y` (built-in)
  and `CONFIG_DRM_RADEON is not set` (radeon not even in the
  kernel). `modprobe.blacklist=` only affects loadable modules.
  Both drivers were already loaded into the kernel image at build
  time; the cmdline did nothing.
- What this tells us: nothing definitive about whether DRM is the
  cause. The test was effectively "stock 6.x boot with init=/bin/sh"
  which still hung, so we know **userspace is not the problem** —
  the kernel itself is hanging before /bin/sh would have started.
- **Next time, to actually disable amdgpu**: either rebuild with
  `CONFIG_DRM_AMDGPU=n` (and likely `CONFIG_DRM=n`), or pass
  `amdgpu.modeset=0` cmdline (works for built-in drivers).

(Add new entries above this line as experiments accumulate.)
