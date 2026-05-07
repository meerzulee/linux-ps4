# 04 — The 6.x port: status, deltas, suspect patches

The 6.x patch set lives in `patches/6.x-baikal/`. It targets vanilla
`v6.15.4`. The bulk of the forward-port was done by **crashniels**
(`ps4-linux-6.15.y-baikal`, HEAD `b3b6b1e4f`); we sliced their tree
into per-subsystem patches mirroring the 5.4 layout, then layered
two small fixes on top.

**Current state**: builds cleanly with GCC 15. Boots through early
init (~0.66s, ~120 lines of UART output via earlycon), then **hangs
silently** before fbcon takeover completes. HDMI black, SSH never
comes up.

This document maps each 5.4 patch to its 6.x status and identifies
the suspects for the late-init hang.

## Patch coverage at a glance

| 5.4 group | 6.x status | Notes |
|---|---|---|
| 0100 x86-platform | ✅ Ported | Conceptually identical; minor head64.c context delta. |
| 0200 ps4-drivers | ⚠️ Partial — UART patch disabled | 0001 (MFD), 0002 (icc fix) ported; 0003 (UART port.type) **commented out** in series. |
| 0300 gpu-liverpool | ✅ Ported, expanded | crashniels added radeon Liverpool support and amdkfd CIK quirks (3 extra patches in 6.x). |
| 0400 storage-ahci | ✅ Ported | Stable. |
| 0500 storage-sdio | ✅ Ported | Stable. (No effect because mt7668 isn't ported yet.) |
| 0600 wifi-mt7668 | ❌ Missing | Not in any 6.x reference tree. Tracked in 9000-todo. |
| 0700 network-sky2 | ✅ Ported | Stable on paper. |
| 0800 usb-aeolia | ✅ Ported, +1 fix | feeRnt's xhci-aeolia-baikal-shutdown.patch added (was inverted before). |
| 0900 hwmon | ✅ Ported | Stable. |
| 1000 iommu | ⚠️ Ported with API churn | Directory moved to `drivers/iommu/amd/`; new code at `iommu.c:irq_remapping_select()` for Aeolia MSI. |
| 1100 pci-msi | ⚠️ Heavily refactored | MSI subsystem split across `vector.c`/`io_apic.c`/`irqdomain.c`. Whole new `x86_fwspec_is_aeolia()` abstraction. |
| 1200 misc | (empty) | bootparam enum likely already merged elsewhere. |

13 patches applied (vs 13 in 5.4), one disabled (UART port.type),
one missing (mt7668).

## What 6.x added that 5.4 didn't have

crashniels' 6.x port includes patches that 5.4 didn't need because
the kernel landscape was different:

- **`0300/0002-radeon-add-liverpool-cik-support.patch`** — Adds
  Liverpool support to the **legacy** `drivers/gpu/drm/radeon/`
  driver, in addition to amdgpu. In 5.4, only amdgpu support was
  needed. In 6.x, both code paths exist and apparently both are
  exercised at probe time.

- **`0300/0003-amdkfd-cik-ps4-quirks.patch`** — Adds CIK GFX7 quirks
  to amdkfd (the compute-driver part of amdgpu). 5.4's amdkfd didn't
  need these; the driver was simpler then.

- **`0300/0004-drm-bridge-and-pciids.patch`** — Splits some
  bridge / PCI-ID glue into its own patch (in 5.4 this was bundled).

- **`0200/0002-ps4-bpcie-icc-fix-ioread-iowrite-pointer-types.patch`**
  — Type fix for `ps4-bpcie-icc.c`: `u32 addr` → `void __iomem *addr`.
  The original code had this bug too; modern compilers (Clang 16+,
  GCC 14+) reject it where older ones warned. This patch is in both
  5.4 and 6.x series now. **Not a porting risk; just a compile fix.**

- **`0800/0002-xhci-aeolia-baikal-shutdown.patch`** — feeRnt's
  `b0969f7d101f` fix. Original `xhci-aeolia` shutdown logic was
  "if NOT Belize, take generic shutdown path", which misclassified
  Baikal. Inverted to "ONLY Aeolia takes generic path". Critical for
  proper Baikal shutdown behavior.

## What changed between 5.4 and 6.x where it matters

### IRQ / MSI subsystem (1100) — the big one

The 5.4 patch was small: add Sony device IDs, skip phantom Aeolia
functions in PCI scan, and one NULL check in `msi_domain_prepare_irqs`.

The 6.x patch is **substantially larger and reaches deeper into the
kernel**. The reason is that the MSI subsystem was rewritten between
5.4 and 6.x:

- 5.4: `arch/x86/kernel/apic/msi.c` was the locus of MSI handling.
- 6.x: that file was split across:
  - `drivers/pci/msi/irqdomain.c` (PCI MSI domain code)
  - `kernel/irq/irqdomain.c` (generic IRQ-domain core)
  - `arch/x86/kernel/apic/io_apic.c` (legacy IOAPIC)
  - `arch/x86/kernel/apic/vector.c` (vector allocation)
  - `include/linux/msi.h` (struct layout changes)

The 6.x patch has to:

1. **Expose new symbols** that vanilla declares static:
   `x86_vector_msi_compose_msg`, `pci_msi_domain_write_msg`. The PS4
   driver code can't use them otherwise.
2. **Add `x86_fwspec_is_aeolia()`** — a brand-new predicate the IRQ
   domain framework uses to recognize Aeolia/Baikal MSI sources.
   This abstraction didn't exist in 5.4; it had to be invented.
3. **Modify `arch_dynirq_lower_bound()`** with new logic for
   Aeolia-routed IRQs.
4. **Reorganize MSI compose-message dispatch** so PS4's custom MSI
   handler gets called for Aeolia-MSI parents.

This is, in software-archeology terms, a **lot of new code in a
volatile area**. If the Aeolia MSI routing predicate fires too late,
or returns the wrong answer for Baikal's MSI domain, devices that
need MSI (xHCI, AHCI, sky2) won't get IRQs and will hang at probe.

### IOMMU subsystem (1000) — directory move + API change

5.4: code at `drivers/iommu/amd_iommu_init.c`. Patch wraps a couple
of IOAPIC-related checks in `#ifndef CONFIG_X86_PS4`.

6.x: code moved to `drivers/iommu/amd/{init.c,iommu.c}`. The patch
targets the new layout. **Plus** the 6.x version adds *new* code
to `iommu.c:irq_remapping_select()` that recognizes Aeolia-MSI via
`x86_fwspec_is_aeolia()` (introduced by 1100).

There's a leftover `pr_err("Remapping Selected: %x\n")` in the 6.x
IOMMU patch that screams "debug print I forgot to remove". Suggests
the patch was in active development when crashniels published it.

If the IOMMU patch interacts badly with the 1100 MSI patch (for
instance, if `x86_fwspec_is_aeolia()` returns wrong on Baikal),
you'd get silent IRQ remapping failures → silent device probe
hangs. **Top suspect for the boot hang.**

### DRM bridge / amdgpu (0300) — volatile API

DRM in mainline changed substantially 5.4 → 6.x:

- Atomic modesetting fully replaced legacy mode-set in many places.
- Display Core (DC) reorganized; some headers moved.
- `drm_bridge_funcs` callbacks gained new methods.
- `drm_connector_init_with_ddc()` signature differs.
- `amdgpu_connector_dvi_encoder()` may not exist or be renamed.

crashniels did the 5.4 → 6.x port for these patches and the code
**looks** correct, but the GPU/bridge initialization is a complex
state machine. If anything fails in `ps4_bridge_attach()` or
`drm_atomic_helper_check()`, the kernel often hangs waiting for a
modeset that never completes — which **matches the symptom of "boot
hangs at fbcon takeover"**.

### UART port.type (0200/0003) — disabled, kexec-fault

The 5.4 fix for `uart:unknown` was a 4-line patch:
- Set `port.type = PORT_16550A`
- Add `UPF_FIXED_TYPE` flag

In 6.x, applying the same patch causes a triple-fault at kexec —
literally before any kernel output. The serial8250 internals
changed in ways that make `UPF_FIXED_TYPE` + custom MMIO probe path
fight each other. **Currently disabled** in `patches/6.x-baikal/series`:

```
# Disabled for A/B test — re-enable once we confirm whether it causes the
# 6.x kexec triple-fault.
# 0200-ps4-drivers/0003-ps4-bpcie-uart-set-port-type.patch
```

Consequences of leaving it disabled in 6.x:
- `port.type` stays `PORT_UNKNOWN`.
- ttySN devices register but are unusable.
- `console=ttyS0` from cmdline is silent (no transmit).
- We rely entirely on `earlycon` (which writes raw to MMIO from
  the printk path) for boot UART, and on HDMI fbcon for everything
  later.

This is **not** the cause of the boot hang — it's a debug
inconvenience. The hang happens regardless of whether this patch
is applied.

## Where 6.x most likely dies — ranked

Based on what's ported, what changed most, and the symptom (silent
hang ~0.66s into UART, before fbcon takeover):

### Tier 1 — almost certain (50%+ probability)

1. **MSI/IOMMU interaction (1000 + 1100)** — the new
   `x86_fwspec_is_aeolia()` predicate is the linchpin of MSI routing
   on 6.x. If it returns wrong for Baikal, MSI delivery breaks
   silently for xHCI / AHCI / sky2. The leftover `pr_err` in 1000
   is a tell that this patch was in development. **Strong candidate.**

### Tier 2 — likely (20–40%)

2. **DRM/amdgpu Liverpool bridge (0300)** — DRM volatility plus the
   "hang at fbcon takeover" symptom matches a stuck modeset. Check
   `ps4_bridge_attach()` and atomic helper interactions.
3. **AHCI PHY init (0400)** — DMA mask API changed; if storage probe
   hangs, the rootfs mount in initramfs would never resolve. Symptom
   would actually present as "switch_root timeout" though, not
   silent hang at fbcon.

### Tier 3 — possible (10–20%)

4. **Aeolia phantom-device PCI scan (1100)** — if the slot-skip
   logic regressed, PCI enumeration could loop or fault.
5. **xHCI Aeolia (0800)** — initialization probe sequence may have
   changed; the new shutdown patch (0002) suggests the area was
   buggy.

### Tier 4 — possible but secondary

6. **Toolchain regression** — we build 6.x with GCC 15. crashniels
   built with their own toolchain (TBD which). If GCC 15 generates
   different code in critical paths (e.g., SMP startup), it could
   hang. Easy to test: rebuild with GCC 14.
7. **Vanilla 6.15.4 quirk** — newer mainline kernels have introduced
   regressions on AMD platforms before. Worth checking the
   `vanilla-6.15.4` repo for known issues against `Family 16h`.

## Diagnostic strategy

The cheapest experiments first ([07-failure-analysis.md](07-failure-analysis.md)
ranks them):

1. **Build crashniels' tree as-is** with no slicing. If their tree
   boots, the issue is in our patch slicing. If it doesn't, the
   issue is upstream of us.
2. **Disable amdgpu/radeon/amdkfd** via Kconfig (`CONFIG_DRM_RADEON=n`,
   `CONFIG_DRM_AMDGPU=n`). If the kernel boots without GPU drivers,
   the hang is in 0300.
3. **Disable IOMMU via cmdline**: `iommu=off amd_iommu=off`. If 6.x
   boots, the hang is in 1000 or 1100.
4. **`init=/bin/sh` + `nofb` + GPU blacklist** — already tried
   (2026-05-07 morning), still hung. Indicates the hang is **not**
   in userspace and **not** in fbcon takeover specifically.
5. **`initcall_debug`** — kernel logs every initcall to fbcon as it
   runs. The last `initcall: <function>+0x..` line printed before
   the hang is the culprit. **This is the most informative single
   experiment.** Photo of HDMI when hung shows the answer.

Next: [05-uart.md](05-uart.md) — UART internals, MMIO offsets, why ttyS4 transmit
is broken, and how earlycon saves us.
