# What we learned getting PS4 Linux to boot

A timeline of dead ends and wins from the 2026-05-06 → 2026-05-08 sessions, kept here so we don't relearn the same things.

## TL;DR

| Component | Verdict |
|---|---|
| Our self-built **5.4 kernel** (Clang 22, LLVM 22) | Compiles, hangs at kexec on PS4. Don't trust modern Clang for 5.4. |
| Our self-built **6.x kernel** (GCC 15) | Compiles, hangs at kexec on PS4. (Could be loader, not kernel — retest needed with v24b payload.) |
| feeRnt's prebuilt **5.4 Clang-14** bzImage | **Works**. This is the baseline. |
| feeRnt's prebuilt **5.4 GCC-11** bzImage | Crashes at kexec when paired with the OLD per-firmware payload. Untested with v24b. |
| Old per-firmware payload `payload-1200-Xgb-baikal.bin` | Triple-faults the kernel on every kexec. Don't use. |
| New unified payload `linux-XXXXmb.bin` (ArabPixel v24b) | **Works**. Auto-detects Baikal at runtime, disables IOMMU. |
| `pacstrap` from CachyOS host into PS4 ext4 | Crashes with "Attempted to kill init! exitcode=0x0000000b" — userspace ISA mismatch. |
| deeWaardt's "Arch - Baikal Ed." tarball | **Works**. v2-baseline binaries, no SIGILLs. |
| better-initramfs External HDD variant (DionKill repo) | **Works**. Auto-mounts `LABEL=psxitarch` after 10 s and switch_root's. |

## The biggest gotcha: PS4 Jaguar is x86-64-v2

The PS4 Jaguar APU lacks AVX2 / BMI1 / BMI2 / FMA / LZCNT — it has AVX1 + F16C + MOVBE + AES-NI + everything up to SSE4.2. That maps to roughly **x86-64-v2 + AVX1**, **NOT** v3.

Modern Arch Linux baseline transitioned to `x86-64-v3` in 2024. CachyOS goes further. So any rootfs you `pacstrap` from a modern Arch-family host contains v3-only opcodes (AVX2 vpermd, BMI bzhi, FMA, etc.).

The first thing systemd does after `switch_root` is execute one of those instructions. PS4 CPU raises `#UD`. The kernel dispatches it as SIGILL/SIGSEGV. Init dies. Kernel panics:

```
init[1]: segfault at ... 
Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

`exitcode=0x0000000b` = signal 11 = SIGSEGV.

**Fix:** never pacstrap into a PS4 rootfs from a modern host. Use one of:
1. A community-built tarball pinned to v2 baseline (deeWaardt's "Arch - Baikal Ed." is what worked).
2. A pre-2024 Arch bootstrap tarball.
3. A non-Arch distro that still ships baseline x86_64 (Debian Forky, Void, Alpine).

## Confirming the CPU features

From the FreeBSD bootloader's CPU print on this user's PS4 (same on all Baikal Slims):

```
Features=0x178bfbff <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2,HTT>
Features2=0x36d8220b <SSE3,PCLMULQDQ,MON,SSSE3,CX16,SSE4.1,SSE4.2,MOVBE,POPCNT,AESNI,XSAVE,AVX,F16C>
AMD Features=0x2e500800 <SYSCALL,NX,MMX+,FFXSR,Page1GB,RDTSCP,LM>
AMD Features2=0x154837ff <LAHF,CMP,SVM,ExtAPIC,CR8,ABM,SSE4A,MAS,Prefetch,OSVW,IBS,SKINIT,WDT,NodeId,Topology,PerfCtrExtNB>
```

No AVX2, no BMI, no FMA, no LZCNT.

## The second-biggest gotcha: the loader payload

Old per-firmware Baikal payloads (`payload-1200-2gb-baikal.bin` and friends) were built before kernel 5.4 quirks were ironed out. Every kexec from those payloads triple-faulted the kernel — we saw `kexec: About to relocate and jump to kernel` followed immediately by the **PS4 firmware secure-loader rebooting**, which means the kernel hard-faulted in microseconds.

ArabPixel's **v24b** is a unified, firmware-agnostic, southbridge-agnostic payload (rmuxnet's rewrite). It correctly detects Baikal at runtime and disables IOMMU before the kexec. Once we switched to v24b, the kernel got far enough to actually run /init.

Get the latest from `ArabPixel/ps4-linux-payloads/releases`. Pick the `linux-1024mb.bin` for first install, switch to a higher-VRAM one later.

## bootargs that work

```
console=tty0 console=ttyS0,115200n8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

What we **removed** from earlier bootargs and why:

- `root=UUID=...` / `rootfstype=ext4 rw`: better-initramfs already mounts `LABEL=psxitarch` itself; explicit root args don't help and can confuse the early-boot path.
- `earlyprintk=serial,ttyS0,115200`: targets legacy 8250 at I/O port `0x3F8`. PS4 doesn't have anything at that I/O port. The kernel hangs immediately on first early-print attempt. **Always strip earlyprintk= for PS4** — there's no equivalent because the PS4 BPCIe UART address comes from a runtime-resolved PCI BAR.
- `panic=15`: auto-rebooted before we could read the death screen. Use `panic=0` so the kernel freezes for inspection during debugging.

What we kept and why:
- `console=tty0` — kernel logs go to HDMI fbcon. **Critical for debugging when UART is silent** (and UART is silent post-kexec because the persistent-UART exploit's hooks no longer apply once Linux owns the BPCIe device).
- `console=ttyS0,115200n8` — once the in-kernel BPCIe-UART driver registers ttyS0, our serial cable will see late-boot kernel logs.
- `panic=0` — kernel halts on panic so we can read it.
- `loglevel=8 ignore_loglevel printk.devkmsg=on` — verbose printk, including debug.

## Side gotcha: UART goes silent post-kexec

The `PS4 Permanent UART` payload (Cthulhu/Sleirsgoevy era) hooks the FreeBSD UART driver. As soon as Linux's kexec stub sets up its own page tables and we jump into bzImage, the FreeBSD code is gone — UART output stops in our `ps4uart.py` log too.

Linux *will* eventually print to the same UART once the in-kernel `ps4-bpcie-uart` 8250-glue driver registers `ttyS0`, but that happens fairly late in boot. **Plan to lose UART visibility for a few seconds during kexec hand-off**; rely on HDMI for early kernel boot, on UART for late drivers + userspace.

## Files that were red herrings

- We deleted/recreated `bootargs.txt` several times before realizing the earlyprintk arg was the killer. The same content exists in multiple locations the v24b payload checks (`/mnt/usb0/`, `/mnt/usb1/`, `/data/linux/boot/`, `/user/system/boot/`); whichever it finds first wins, so an old `/data/linux/boot/bootargs.txt` on PS4 internal storage from a previous experiment can override your USB one. Worth checking via FTP if cmdlines look stale.
- An empty `vram.txt` ≠ no `vram.txt`. The payload's compiled-in default is 1024; the file just confirms/overrides.

## UART unlock — earlycon to the right MMIO

After the first successful boot we still had **zero Linux UART output** even though the FreeBSD-side persistent-UART payload had been logging the firmware fine. Tracking it down took several iterations and produced reproducible knowledge worth keeping.

### Root cause of the silence

The PS4's `ps4-bpcie-uart.c` driver registers BPCIe UART instances via `serial8250_register_8250_port()` **without setting `port.type`**. Result in `/proc/tty/driver/serial`:

```
4: uart:unknown mmio:0xC890F000 irq:29
```

`type=unknown` is fatal: the 8250 console layer refuses to write/transmit on a port of unknown type. Even reads fail with `EIO`. So `console=ttyS0,115200n8` (or any `console=ttySN`) goes nowhere — kernel printk has nothing to output to. The standard PC ttyS0..ttyS3 are phantom legacy 8250s at I/O `0x3F8` etc. that the PS4 doesn't physically have.

The proper fix is a kernel patch — see `9000-todo`. Workaround that does *not* need a kernel rebuild: **earlycon**, which writes directly to MMIO from the kernel printk path without going through the regular driver.

### Finding the right MMIO address

`BPCIE_NR_UARTS=2` per `drivers/ps4/baikal.h`, with offsets:

| Index | Offset | Address with BAR2=`0xC8800000` |
|---|---|---|
| 0 | `0x10E000` | `0xC890E000` |
| 1 | `0x10F000` | `0xC890F000` |

We can find BAR2 from `lspci -vv -s 0000:00:14.4` (the BPCIe glue function). It's the second non-prefetchable region.

The Linux 8250 driver registered ttyS4 at `0xC890F000` (UART1). But the user's physical UART cable was wired to **UART0 at `0xC890E000`**. To prove it without a reboot we wrote sentinel bytes via `/dev/mem` to both addresses (script: `checkpoint/docs/uartprobe.py`) — only `0xC890E000` produced output on the cable.

That MMIO address is the one to put in the bootargs:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8
```

Note `mmio32`: every Linux earlycon write transmits a 32-bit dword to the data register. With `regshift=2` the chip select picks the right reg, but the transmitted bytes are still padded with three zero bytes per character (so output looks like `H e l l o` with embedded NULs if you log it raw). Acceptable for debug, ignore the cosmetic spacing.

### `keep_bootcon`: nuanced — kills xhci on **5.4**, but is the diagnostic key on **6.x**

#### On 5.4 (stay away once xhci comes up)

We tried `keep_bootcon` to extend earlycon past the regular console handover so we'd get full-boot UART. **On 5.4 it crashes xhci_aeolia at ~57 seconds.** The BPCIe glue device parents both the UART and the xhci controller (`00:14.7`); constant earlycon writes to UART MMIO appear to overload the bus and the xhci host eventually goes into "not responding" → "HC died" → USB rootfs disappears → ext4 errors → systemd cascade-fails.

So on 5.4 the **stable** bootargs is **earlycon without `keep_bootcon`**:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

Behavior on 5.4:
- 0.000s — earlycon active, UART logs every printk
- ~1.0s — `console=tty0` registers (HDMI fbcon), earlycon retires automatically (`bootconsole [uart8250] disabled` in dmesg)
- ~1.0s onward — kernel output goes to HDMI; UART silent; xhci stays alive

`checkpoint/docs/uart-boot-capture-ttyS0E000.log` is a real capture of the ~135-line UART window for reference.

#### On 6.x (REVISED 2026-05-08 — `keep_bootcon` is FINE here, and necessary for diagnosis)

Earlier we noted "On 6.x, appears to cause immediate hang. Don't use." That diagnosis was **wrong**. The actual root cause was `console=ttyS0,115200n8` in the cmdline directing post-bootconsole printks at a phantom legacy 8250 at I/O `0x3F8` — the kernel was running silently, not hanging.

When we drop `console=ttyS0` AND add `keep_bootcon` (and use `8250.nr_uarts=0` to suppress phantom slot allocation), the 6.x kernel boots **cleanly to userspace `/init` at 7.28 s** with 1753 lines of UART output. It only stops at 17 s because the initramfs can't find `LABEL=psxitarch` (storage drivers stuck in deferred-probe — see "The bpcie_uart cascade" below).

**Working 6.x diagnostic bootargs:**

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 keep_bootcon initcall_debug 8250.nr_uarts=0 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

Why this works:
- `,keep` suffix on `earlycon=` is a syntax mistake — kernel parses it as a clkrate option (`earlycon: [115200n8,keep] unsupported earlycon uart clkrate option`). Use `keep_bootcon` as a **separate** parameter.
- `console=ttyS0,115200n8` is poisonous when no real `ttyS0` exists yet (phantom legacy 8250). Don't add `console=ttySN` until the BPCIe UART driver actually registers a real ttySN AND we know which N.
- `8250.nr_uarts=0` skips legacy 8250 slot allocation entirely. The BPCIe UART driver will create its own slot once it registers (assuming it does — see cascade below).
- `keep_bootcon` is OK on 6.x because xhci-aeolia *isn't even probing* yet (so the "BPCIe bus overload" failure mode that hit 5.4 doesn't manifest until much later, if at all).
- `initcall_debug` is invaluable — every initcall is logged with name, address and elapsed usec. The last line before silence pinpoints the hung initcall.

## The bpcie_uart cascade (6.x's real blocker, 2026-05-08)

Once we got 6.x UART output past 0.66 s, the actual failure showed up at line 1284 of the boot log:

```
baikal_pcie 0000:00:14.4: Failed to register serial port 0
baikal_pcie 0000:00:14.4: bpcie glue remove
baikal_pcie 0000:00:14.4: probe with driver baikal_pcie failed with error -5
```

`drivers/ps4/ps4-bpcie.c::bpcie_probe` is a sequence:

```c
if ((ret = bpcie_glue_init(sc)) < 0) goto free_bars;       // ✅ chip rev printed: 4c0c2021:8d76a398:0000b100
if ((ret = bpcie_uart_init(sc)) < 0) goto remove_glue;     // ❌ FAILS HERE on 6.x
if ((ret = bpcie_icc_init(sc)) < 0)  goto remove_uart;     // unreached
```

`bpcie_uart_init` calls `serial8250_register_8250_port` for each of the two BPCIe UARTs. On 6.x's `serial8250` autoconfig, the port is rejected because no `port.type` is set (we don't carry the `0003-ps4-bpcie-uart-set-port-type.patch` on 6.x). The current bpcie_probe treats this as fatal and tears down the entire southbridge.

**Cascading consequence:** every PS4 child driver that gates on `apcie_status() == 1` defers forever:
- `amdgpu` defers on `0000:00:01.0` (517 = -EPROBE_DEFER, repeated each retry)
- `xhci-aeolia` defers on `0000:00:14.7`
- `ahci` defers on `0000:00:14.2`
- `sdhci-pci` actually detects the controller (`SDHCI controller found [104d:90da] (rev 0)`) but probe defers anyway
- `sky2` defers waiting on apcie status

Result: kernel reaches `/init` because nothing in core kernel is broken, but the initramfs spins on `LABEL=psxitarch: Can't lookup blockdev` because the rootfs is on USB ext4 and USB is offline.

### Two ways to fix the cascade

1. **(small change, fast)** Make `bpcie_uart_init` failure non-fatal. UART is debug; it doesn't need to gate ICC, AHCI, XHCI, etc. Patch sketch in PLAN.md "Next-session priority list".

2. **(bigger change, more correct)** Fix the underlying 8250 registration via the `0003-ps4-bpcie-uart-set-port-type.patch` (sets `port.type = PORT_16550A` + `UPF_FIXED_TYPE`). The patch was disabled on 6.x because it triple-faulted at kexec — but that was probably co-occurring with broken bootargs. Worth retrying.

## bootargs cheat sheet (post-2026-05-08)

| Scenario | Bootargs |
|---|---|
| **5.4, normal boot** | `earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on` |
| **6.x, diagnostic boot (KEEP UART alive past 0.66 s)** | `earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 keep_bootcon initcall_debug 8250.nr_uarts=0 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on` |
| **bypass systemd** | append `init=/bin/sh` |
| **Don't use** | `earlyprintk=...`, `console=ttyS0,...` on 6.x without bpcie UART, `panic=15` (auto-reboot) |

### When the kernel boot fails silently and the screen shows just `_`

That underscore is the firmware's leftover cursor. Here's the rundown:
- Just `_`, no UART, no rebooting → kernel jumped, hung in *very* early init before any console came up. Earlycon should give us one or more lines before this happens. If we see literally nothing and `_` stays put, the kernel jumped to bad memory or triple-faulted before earlycon could initialize.
- Just `_` + PS4 reboots back to firmware in ~milliseconds → triple-fault. Used to be every kexec attempt with old per-firmware payloads; v24b fixed this.

## D + revert A: even forcing IR doesn't help (2026-05-09, boot #14)

After Option A landed cleanly but didn't fix MSI delivery (boot #13),
tried Option D (force kernel-side IR via `iommu=on amd_iommu=on
intremap=on amd_iommu_dump=on` bootargs) WITH Option A REVERTED so
bpcie_create_irq_domains runs again.

Result:

  [ 2.310] AMD-Vi: Interrupt remapping enabled                ← IR is ON
  [ 4.967] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs:
                                     requested nvec=3 msi_enabled=0
  [ 4.975] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs
                                     returning 1 (dev->irq=33)   ← STILL clamped
  [ 7.203] Spurious interrupt (vector 0xef) on CPU#0. Acked
  [14.533] Error while assigning device slot ID: Command Aborted

Even with IR enabled at the kernel level AND bpcie_create_irq_domain
restored, `bpcie_assign_irqs` still returns 1. That means
`bpcie_msi_domain_info.flags & MSI_FLAG_MULTI_PCI_MSI` is still
false in our context — i.e. inside `bpcie_create_irq_domain`,
`irq_remapping_get_ir_irq_domain(&info)` returns NULL for our
slot-20 PCI devices.

Two breakage layers, both confirmed:
1. The kernel's IR domain isn't attaching to our hand-crafted slot-20
   PCI bus (so bpcie can't find an IR parent domain to inherit from).
2. Even if it could, the legacy `dev_set_msi_domain()` is ignored by
   6.x's PCI MSI core anyway (the original Linux 6.2 rework finding).

Conclusion: **D is dead.** D was supposed to "force the per-function
domain to start working" by giving it an IR parent. It can't because
neither the kernel's IR setup nor the legacy domain-attach reach our
PCI hierarchy on this hardware in 6.x.

Re-enabling Option A as the baseline (bpcie's per-function domain
creation is structurally broken on 6.x; skipping it is at minimum
not worse than letting it run uselessly).

**Only B (per-device MSI parent domain via msi_create_parent_irq_domain
+ msi_parent_ops) remains as a real fix.** C still worth spending 30
min on as a sanity check, but the pattern of failures argues B is
necessary regardless.

## Option A landed but isn't enough (2026-05-09, boot #13)

Built and booted with patch 0006 (skip bpcie per-function MSI domain
creation, drop nvec=1 clamp).  Patch is confirmed active:

  [ 4.449] baikal_pcie 0000:00:14.4: bpcie: child MSI domains
                                     intentionally not created on 6.x
  [ 4.806] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs:
                                     requested nvec=3 msi_enabled=0
  [ 4.814] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs
                                     returning 3 (dev->irq=33)

**Real progress**: bpcie no longer interferes; nvec clamp gone (3
vectors allocated instead of 1). xhci-aeolia uses the kernel's
default PCI MSI path. None of bpcie's MSI hooks fire.

**Still broken**: xHCI fires MSIs but they all land as
APIC_SPURIOUS_VECTOR (0xef). Now we see **five** spurious vectors
between bus registration and the first Command Aborted, vs two
before. Command Aborted still happens at exactly the same 14.485 s
mark.

This means the kernel's *default* PCI MSI path is allocating LAPIC
vectors but **not actually programming them into xHCI's MSI
capability** — or programming them with wrong vector data. Vector
allocation works, message-write step is missing or broken.

That's the fingerprint of **Linux 6.2's per-device MSI architecture**
expecting a *child* per-device MSI domain to handle the cap
programming, with the standard x86 vector domain only acting as
parent. Our child pdevs (xhci, ahci, sdhci, sky2 — accessed via
`pci_get_slot()` from bpcie_assign_irqs) don't get a default
per-device MSI domain set up the way a normally-enumerated PCI
device would.

bpcie's *own* pdev (function 14.4) works fine — its ICC subfuncs
deliver MSIs correctly. The difference is probably that the kernel's
PCI bus enumeration creates a per-device MSI domain for it during
normal probe, but `pci_get_slot()` lookups don't trigger that init.

### Remaining options after boot #13

- **B** — port bpcie to the per-device MSI parent-domain API
  (msi_create_parent_irq_domain + msi_parent_ops). The architecturally
  correct fix. ~100–150 LOC. Use a recent simple PCI controller
  migration (pcie-rcar, pcie-xilinx) as template.

- **C** — figure out why default per-device MSI domain isn't getting
  installed for our child pdevs. Possibly a small fix if we find the
  missing init.

- **D** — try `intremap=on` or similar bootargs to force the kernel
  to enable interrupt remapping. The loader hard-disables AMD-Vi but
  maybe the kernel can re-enable IR alone. Cheapest test (1-line
  bootargs change). If it works, MSI_FLAG_MULTI_PCI_MSI may light up
  through different paths.

Quick-cost ranking: D (minutes) → C (~30–60 min research) →
B (~2-3 h coding).

## `pci=nomsi` test refines Option A boundary (2026-05-09)

After identifying Linux 6.2's MSI rework as the root cause, tried
Option D from the fix path list — boot with `pci=nomsi` to force
legacy IRQ. Result was inconclusive but informative:

  [ 4.574] baikal_pcie 0000:00:14.4: Failed to assign IRQs
  [ 4.580] baikal_pcie 0000:00:14.4: bpcie glue remove
  [ 4.585] probe with driver baikal_pcie failed with error -5

`pci=nomsi` is too coarse: it disables MSI globally, but bpcie itself
needs MSI for its own subfunc IRQ pool (ICC, UART, MSI demuxer). With
nomsi, bpcie's `pci_alloc_irq_vectors(sc->pdev, ICC+1, BPCIE_NUM_SUBFUNCS,
PCI_IRQ_MSI)` in `bpcie_glue_init` returns -ENOSPC, bpcie probe
aborts entirely, every PS4 child driver defers forever, `/init`
reaches but rootfs lookup loops (same end-state as the
pre-0004-non-fatal era, different cause).

Side benefit: confirms that `Command Aborted` IS gone with nomsi,
because xhci-aeolia never even probes when bpcie is dead. So MSI
delivery genuinely is the issue, just on the **child** path, not
in bpcie's own IRQ pool.

The actual diagnostic we wanted — keep MSI for bpcie's own use,
disable it just for child PCI devices — needs a kernel-side patch
because there's no cmdline knob that scoped.

### Updated Option A boundary

Original framing: "skip bpcie's custom MSI domain on Baikal."
Refined now with precise scope:

- **Keep** `pci_alloc_irq_vectors` for bpcie's *own* pdev (function
  14.4 — needs ICC + UART subfuncs).
- **Skip** the per-function `bpcie_create_irq_domain` loop that runs
  inside `bpcie_glue_init` for slots 14.0..14.7's pdevs. That's where
  the broken `dev_set_msi_domain()` calls live.
- **Skip** the `bpcie_msi_domain_info` setup for child devices.
- **Skip** the `bpcie_handle_edge_irq` demuxer — never useful in
  shared-vector mode anyway.
- xhci-aeolia, ahci, sdhci-pci, sky2 then call the standard PCI MSI
  path (default kernel domain, which 6.x sets up correctly via the
  per-device MSI infrastructure for any PCI device).
- Aeolia/Belize unaffected — apcie's MSI is hardware-demuxed and
  works differently.

That should be ~30 LOC of removals + a couple of guarding ifs.
Patch coming next.

## Root cause: Linux 6.2 reworked MSI domain lookup (2026-05-09)

Web research after the diagnostic boot (#12) found the kernel-side
change that explains the symptom. From Phoronix and LWN:

- "Linux 6.2 Brings A Big Rework To The MSI Subsystem" (Phoronix).
- "genirq, PCI/MSI: Support for per device MSI and PCI/IMS — Part 3
  implementation" (Thomas Gleixner / Ahmed Darwish, merged late 2022).

The bulk of the rework landed in **Linux 6.2** and introduced
per-device MSI interrupt domains. The old API (`pci_msi_create_irq_domain`
+ `dev_set_msi_domain` to attach to a pdev) **still exists** in 6.15
— `dev_set_msi_domain` writes the legacy `dev->msi_domain` field —
but PCI MSI core now walks a different lookup path that prefers a
per-device domain in `dev->dev.msi.data->__domains[]` over the legacy
single-pointer field.  If only the legacy field is set, the
allocation falls back to the standard x86 vector domain, which is
exactly what we observed (xhci IRQ ends up at virq 33 with no bpcie
hooks fired).

That makes the bpcie code an anachronism on 6.x: the domain is
created, dev_set_msi_domain marks the device, and then nothing reads
it.  On 5.4 the same code worked because the lookup walked the
legacy field directly.

### Fix-path options

A. **Skip bpcie's custom MSI domain on Baikal.** In shared-vector
   mode (no IOMMU-IR — production case) bpcie_assign_irqs() forces
   nvec=1 anyway, so the per-subfunc demuxer never had anything to
   demux to.  Let xhci-aeolia call the standard pci_alloc_irq_vectors
   straight through the x86 vector domain on Baikal.
   Aeolia/Belize keep apcie's domain (they actually need hardware
   MSI demuxing).  Smallest diff.  **Recommended.**

B. Port bpcie to the new per-device MSI parent-domain API
   (`msi_create_parent_irq_domain` + `msi_parent_ops`).  Correct way
   forward, big rewrite.

C. Also write into `dev->dev.msi.data->__domains[]` after the legacy
   `dev_set_msi_domain`.  Minimal, but unclear if 6.x actually
   accepts a domain installed that way without going through
   `msi_create_device_irq_domain`.

D. Boot with `nomsi` or `pci=nomsi` in bootargs.  Forces legacy
   line-based IRQ.  Lower performance, but could be a debug step
   to confirm the MSI path is the entire issue.

Diagnostic patch (`9001-DEBUG-bpcie-msi-trace.patch`) stays in the
tree for repeat tests but is **not in series** by default once we
land the real fix.

## bpcie MSI domain is NEVER USED on 6.x (2026-05-09, boot #12)

After all the xHCI / settle / IRQ / demuxer patches, we added
diagnostic `pr_info` to four bpcie MSI-path functions:
`bpcie_assign_irqs`, `bpcie_msi_init`, `bpcie_msi_write_msg`,
and `bpcie_handle_edge_irq`. Boot #12 shows:

```
[ 4.929860] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs: requested nvec=3 msi_enabled=0
[ 4.938093] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs returning 1 (dev->irq=33)
[ 7.158757] Spurious interrupt (vector 0xef) on CPU#0. Acked
[ 7.460710] Spurious interrupt (vector 0xef) on CPU#0. Acked
[14.670647] Error while assigning device slot ID: Command Aborted
```

**Only `bpcie_assign_irqs` logs. Zero output from `bpcie_msi_init`,
`bpcie_msi_write_msg`, or `bpcie_handle_edge_irq`.**

That means: the bpcie MSI domain is created (via
`pci_msi_create_irq_domain` + `dev_set_msi_domain`) but the kernel's
PCI MSI allocator is **not walking it** when xhci-aeolia calls
`pci_alloc_irq_vectors`. The IRQ ends up on `irq=33` via some other
path — almost certainly the standard x86 vector domain. The MSI
capability gets programmed with a LAPIC vector that the LAPIC then
delivers as **spurious vector 0xef** (APIC_SPURIOUS_VECTOR) — meaning
the controller is firing MSIs but the kernel doesn't recognise them
as belonging to any registered handler. xHCI's command-completion
interrupt is therefore lost, the kernel hits TRB_RING_TIMEOUT (5 s),
gives up, and reports Command Aborted.

This is a **6.x infrastructure mismatch**, not a vendor MSI message
bug. The bpcie code worked on 5.4 because `dev_set_msi_domain` +
`pci_msi_create_irq_domain` was sufficient there. In 6.x the device's
PCI MSI domain is looked up via a different mechanism that ignores
our setting (suspected: `dev->dev.msi.data` chain or the PCI bridge
walk added in 5.10/5.15/6.0).

Diagnostic patch retained at
`patches/6.x-baikal/0200-ps4-drivers/9001-DEBUG-bpcie-msi-trace.patch`
for future re-runs. **Revert before any production-intent build.**

Implication: the previous five patches (0005 settle, 0006 apcie IRQ,
0007 imod+retry, 0005 demux bypass, 0003 iommu coherent-DMA) are
correct individually, but none of them help because the MSI never
reaches the bpcie code path. The actual fix has to be at the domain
creation level — making 6.x's PCI MSI core honour our
`dev_set_msi_domain()` association.

## The bpcie shared-vector demuxer was broken on every Baikal port (2026-05-09)

After landing four xHCI-side patches in a row that did NOT change the
"Command Aborted" symptom (msleep 50/20, IRQ-via-apcie, imod_interval
+ caps retry, plus the inline IOMMU coherent-DMA fix), the diagnosis
finally moved to the bpcie code itself.

The smoking gun was a single line in the boot log:

  [    4.928] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs(3)
  [    4.934] xhci_aeolia 0000:00:14.7: bpcie_assign_irqs returning 1

`bpcie_assign_irqs` clamps nvec to 1 when MSI_FLAG_MULTI_PCI_MSI is
not set — which is the case whenever IOMMU-IR is off, which is the
*production* case on Baikal (ArabPixel's loader explicitly disables
AMD-Vi IR before kexec). In that mode `bpcie_msi_domain_set_desc`
ORs `0x1F` into the msi_hwirq:

```c
arg->msi_hwirq |= 0x1F;     /* shared mode: hwirq | 0x1F */
```

So the *one* MSI vector that gets allocated for each PCI function
lands at hwirq `0x14XF` (X is the function number).  No child virqs
are created at hwirq `0x14E0`, `0x14E1`, `0x14E2` etc.

But `bpcie_handle_edge_irq()` — the irq flow handler installed for
every virq in the bpcie MSI domain — does this on every interrupt
for functions 4 / 5 / 7:

```c
u32 initial_hwirq = desc->irq_data.hwirq & ~0x1fLL;   /* 0x14E0 */
...
for (i = 0; i < 32; i++) {
    if (subfunc_mask & (1 << i)) {
        unsigned int virq = irq_find_mapping(domain,
                                             initial_hwirq + i);
        ...
        handle_edge_irq(new_desc);
    }
}
```

In shared-vector mode there is NO virq mapped at `initial_hwirq + i`
for any i ≤ 4.  Every iteration calls `irq_find_mapping()` that
returns 0; `irq_to_desc(0)` resolves to nothing; the dispatch silently
does nothing. **The xHCI command-completion MSI is swallowed.** The
kernel waits TRB_RING_TIMEOUT (5 s) for the command to complete,
gives up, and reports:

```
xhci_aeolia 0000:00:14.7: Error while assigning device slot ID:
                          Command Aborted
usb usb1-port1: couldn't allocate usb_device
```

**This explains why USB device enumeration has been broken on every
6.x-Baikal port that doesn't run with IOMMU-IR enabled.** The bug has
been there since whitehax0r/feeRnt's tree imported the BPCIe MSI code
from the original PS4 5.4 squash.

### The fix

`patches/6.x-baikal/0200-ps4-drivers/0005-ps4-bpcie-shared-vector-demux-bypass.patch` —
detect shared-vector mode at the top of `bpcie_handle_edge_irq()` by
checking whether the hwirq has all-1s in the bottom 5 bits.  If so,
bypass the per-subfunc demux entirely and run the standard
`handle_edge_irq(desc)` against the shared parent virq directly.  The
registered driver handler (`xhci_irq`, `ahci_irq`, `bpcie_icc_init`'s
ICC interrupt handler, ...) reads its own status register to decide
whether the IRQ was for it — which is exactly how `IRQF_SHARED`
interrupts already work everywhere else in the kernel.

Diagnostic timeline:
- Boot #4: bpcie cascade fixed by 0004-uart-non-fatal — baseline.
- Boot #5: 0005 (settle delays) — Command Aborted unchanged.
- Boot #8: 0006 (IRQ-via-apcie) — semantic no-op, unchanged.
- Boot #9: 0007 (imod_interval + caps retry) — retry path never
  triggered (xhci_gen_setup succeeds), unchanged.
- Boot #10 (clean rebuild): identical state to boot #9, ruling out
  cache.
- Diagnosis from boot #10 logs: `bpcie_assign_irqs returning 1`,
  both xhci controllers on irq 33, two spurious vector-0xef
  interrupts.  Read bpcie_handle_edge_irq source, found the
  shared-vector hwirq path lands in dead code.

## The bpcie cascade is gone (2026-05-08, third boot)

After applying `0004-ps4-bpcie-make-uart-failure-non-fatal.patch`, bpcie_probe completes for the first time on 6.x. The fix path fires verbatim:

```
[    4.591198] baikal_pcie 0000:00:14.4: UART init failed (-5); continuing without serial console
[    4.726768] probe of 0000:00:14.4 returned 0 after 296013 usecs
```

Everything downstream that gates on `apcie_status() == 1` now probes:
- `xhci-aeolia` (0000:00:14.7) — probes successfully, registers 4 USB buses, USB 3.0 SuperSpeed claimed, Belize SATA PHY init runs to completion (`PHY SET GEN3`), inline AHCI claims 6 Gbps / 32 cmd slots.
- `sdhci-pci` (0000:00:14.3) — finds mmc0 ADMA controller, probe returns 0.
- `bpcie_icc_init` runs all the way through (icc_pwrbutton_init has one non-fatal -EAGAIN on reset notifications, expected).

**New blockers** observed in `checkpoint/docs/uart-boot-2026-05-08-6x-bpcie-non-fatal.log`:

1. **`xhci_aeolia 0000:00:14.7: Error while assigning device slot ID: Command Aborted`** at 14.5 s. xHCI host is up but device enumeration fails — no /dev/sdX appears, so initramfs can't find `LABEL=psxitarch`. This is the dominant blocker.
2. **`ahci 0000:00:14.2: probe with driver ahci failed with error -12`** at 10.7 s. -ENOMEM from the dedicated HDD AHCI controller. Suspect coherent-DMA shape — `iommu-amd-fix-ps4-baikal-coherent-dma.patch` from rmuxnet-7.0-baikal is the likely fix.
3. **`mmc0: Timeout waiting for hardware cmd interrupt`** at 18 s. SDHCI host registered but no card answer. Could be no eMMC on this model, or a Baikal SDHCI quirk.

Next step: apply rmuxnet's 8 USB/IOMMU patches from `patches/rmuxnet-7.0-baikal/` (already extracted, just need to rebase to 6.15 and stage in our series). See PLAN.md priority #1.

## What's still on the to-do list

- ✅ ~~Retry our 6.x build with v24b payload — earlier failures were against the old per-firmware payload, which always triple-faulted regardless.~~ — Done 2026-05-08.
- ✅ ~~Make `bpcie_uart_init` failure non-fatal in `drivers/ps4/ps4-bpcie.c::bpcie_probe`. ~5 LOC.~~ — Done 2026-05-08. Patch `0004-…` lands cleanly, bpcie cascade gone.
- 🔥 **Cherry-pick rmuxnet's xhci/iommu patches** for the `Command Aborted` device-slot allocation and the AHCI -ENOMEM. 8 patches already extracted in `patches/rmuxnet-7.0-baikal/`. See PLAN.md priority #1.
- Apply `patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate` once boot reaches userspace, validate against PLAN.md "Ethernet over Baikal sky2 — broken".
- Re-enable `0003-ps4-bpcie-uart-set-port-type.patch` once USB is up — gives us proper `ttySN` driver-side UART in addition to the working earlycon.
- Layer kernel modules onto the deeWaardt rootfs so we get WiFi (mt7668) and the rest.
- Cap Mesa at 25.1 in the rootfs (deeWaardt's tarball is already pinned, but watch out on first `pacman -Syu`).
- Resolved: ~~Self-built bzImages hang~~ — wasn't a hang, was UART silence. Builds work fine.

## Linux 6.2 PCI MSI domain rework — the bpcie modernization saga (2026-05-09)

After 0005 (shared-vector demux bypass) didn't move xHCI's Command Aborted, debug
logging showed `bpcie_msi_init`, `bpcie_msi_write_msg`, and `bpcie_handle_edge_irq`
were never being called. Diagnosis pointed at Linux 6.2's per-device MSI domain
rework (Thomas Gleixner / Ahmed Darwish, late 2022): the legacy
`pci_msi_create_irq_domain()` + `dev_set_msi_domain()` API still exists in 6.15
but the kernel's PCI MSI core now walks `dev->dev.msi.data->__domains[]` for the
actual lookup; the legacy `dev->msi_domain` field is left orphaned for any device
that wasn't also installed through `msi_create_device_irq_domain()`.

### Options tried before the right shape clicked

| Option | What it tried | Result |
|---|---|---|
| **A** (skip bpcie domain on 6.x) | Don't call `bpcie_create_irq_domains()`; let children fall through to default x86 vector. | Boot OK, but every Baikal child PCI MSI delivered as `Spurious interrupt (vector 0xef)` on the LAPIC → xHCI `Command Aborted`. The kernel didn't know how to route MSIs through bpcie's hardware demuxer. |
| **B v1** (parent flag + parent_ops only) | Set `IRQ_DOMAIN_FLAG_MSI_PARENT` and provide `msi_parent_ops` with a delegating `init_dev_msi_info`. | Parent flag set 8x. But `bpcie_init_dev_msi_info` never fired — kernel never walked our parent. |
| **C** (per-device default MSI domain) | Considered; would have required reading 6.15's PCI MSI core to find a different injection point. | Skipped in favour of B. |
| **D** (`intremap=on` bootargs) | Force kernel to enable AMD-Vi + IR despite ArabPixel's loader hard-disabling it at `*(0xfc000018) &= ~1`. | IR enabled, but `irq_remapping_get_ir_irq_domain()` returned NULL for slot-20 devices — bpcie's parent lookup still got x86_vector, not an IR domain. |
| **D + revert A** | Combine D with the original bpcie domain creation (un-skip A). | Same dead end. |

### The real bug: bpcie never installed its domain on any pdev

While writing Option B v1, I grepped for `dev_set_msi_domain` in `drivers/ps4/`
and found **zero references**. bpcie creates per-function MSI domains in a loop
(`bpcie_create_irq_domains`) but doesn't install any of them on the corresponding
`pci_dev` via `dev_set_msi_domain()`. This was a latent bug from the 5.4 → 6.x
port: under 5.4 the legacy fwnode-based PCI MSI lookup walked the irq_domain_list
and matched our `"Baikal-MSI"` name implicitly; in 6.2+ that lookup was replaced
by `dev->msi.domain` field-only, so the install became no longer optional.

### Option B iterations

| Version | Change | Boot result |
|---|---|---|
| **v1** | Parent flag + custom `init_dev_msi_info` wrapper | Parent flag set 8x, wrapper never called → MSI still as 0xef spurious. |
| **v2** | v1 + `dev_set_msi_domain(&bpcie_pdev->dev, domain)` install | **Hung at 4.63 s**, immediately after the 8th parent-flag log line. Root cause: our wrapper called `real_parent->msi_parent_ops->init_dev_msi_info(...)` but `real_parent` IS the MSI parent the kernel found (us), so `msi_parent_ops` resolved to OUR ops → infinite recursion → stack overflow. (Notably: USB keyboard worked from this boot — likely the legacy fallback path was already firing for child pdevs before bpcie's own pdev hit the recursion.) |
| **v3** | Replace recursing wrapper with kernel helper `msi_parent_init_dev_msi_info()` (walks `domain->parent` explicitly to x86_vector). | Boot reached `/init` at 7.36 s. But `WARNING ... x86_init_dev_msi_info+0xbd` fired: x86's gating switch on `real_parent->bus_token` only accepts `DOMAIN_BUS_ANY` (when domain == real_parent — for x86_vector itself), `DOMAIN_BUS_DMAR`, and `DOMAIN_BUS_AMDVI`. Our domain had default `DOMAIN_BUS_ANY` but is not x86_vector, so WARN tripped and returned false → all child MSI allocs returned `-EPROBE_DEFER` → `LABEL=psxitarch: Can't lookup blockdev` loop. |
| **v4** | Add `irq_domain_update_bus_token(domain, DOMAIN_BUS_AMDVI)` after marking parent. | x86's WARN gone. But now bpcie itself failed: `baikal_pcie 0000:00:14.4: Failed to assign IRQs` followed by `probe with driver baikal_pcie failed with error -5`. Cause: our `parent_ops.supported_flags` had `MSI_GENERIC_FLAGS_MASK | MSI_FLAG_PCI_MSIX` but **not** `MSI_FLAG_MULTI_PCI_MSI`. The kernel ANDs the per-device child info's flags with our supported_flags, so multi-MSI was masked out. bpcie's own pdev needs ≥ `BPCIE_SUBFUNC_ICC+1 = 5` vectors → `pci_alloc_irq_vectors` returned -ENOSPC → bpcie probe fails → all downstream drivers defer. |
| **v5** | Add `MSI_FLAG_MULTI_PCI_MSI` to `parent_ops.supported_flags`. | Pending hardware test (this commit). |

### Caveat carried forward in v3+

The per-device child domain inherits the standard PCI MSI handler
(`handle_edge_irq` via x86 vector) instead of `bpcie_handle_edge_irq`. The
subfunction demuxer's sibling-lookup pattern
(`irq_find_mapping(desc->irq_data.domain, initial_hwirq + i)`) doesn't translate
to the per-device model where each pdev has its own domain. This is *fine for
xHCI single-vector MSI* (the one MSI vector lands on `xhci_irq` directly without
needing demuxing) but if SDHCI/AHCI/sky2 end up needing the demuxer, the demuxer
itself will need porting to the per-device model — override `info->handler` in
`init_dev_msi_info` AND rework the sibling lookup to walk
`dev->parent`'s `msi.data->__domains[]`. Track as follow-up.

### Marker pattern for finding boot sessions in UART log

`echo "===SESSION-MARKER-..." | sudo tee -a logs/ps4_uart_*.log` works for the
human eye, but pyserial's buffered writes routinely clobber appended markers when
the next batch of incoming serial data flushes. Find the boot by content
signature instead (the `Linux version` line, distinctive new pr_info text).

## Option B v6 — demuxer-leaf-handler override (2026-05-09)

After v5 boot proved the MSI-domain-parent infrastructure works end-to-end (8x
parent flag set, AMDVI bus_token satisfies x86's gate, multi-MSI permits 32+
vectors, real CPU-targeted vectors programmed in every MSI cap, zero spurious
0xef interrupts), the remaining wall in v5 was that `bpcie_handle_edge_irq` —
bpcie's hardware demuxer that reads `BPCIE_ACK_READ` to identify which
subfunction fired — was firing **zero times** in the entire boot. Result:
xhci/sdhci/ahci/even bpcie's own ICC commands all timed out on completion
interrupts.

v6 added a custom `bpcie_init_dev_msi_info` wrapper that calls
`msi_parent_init_dev_msi_info` first (kernel helper for non-recursing parent
delegation), then explicitly overrides `info->handler = bpcie_handle_edge_irq`
and `info->chip_data = bpcie_dev_for_child_pdev(...)` so the demuxer is wired
into the per-device child's leaf chain.

**Result on hardware (Boot #19, 2026-05-09 morning):**

- ✅ `bpcie_init_dev_msi_info` fires for each Baikal child pdev that calls
  `pci_alloc_irq_vectors` (3x in this boot: 14.4 then 14.7 then 14.3).
- ✅ `bpcie_msi_init` fires 34x (parent-level setup OK).
- ✅ `bpcie_msi_write_msg` fires for every MSI cap activation. Real vectors
  programmed (0x20 on CPU 1/2/3 for ICC/xhci/sdhci respectively).
- ❌ **`bpcie_handle_edge_irq` fires 0 times** — same as v5. Override didn't
  propagate to leaf handler despite info->handler being set after the helper.
- ❌ **amdgpu regressed** — `[drm:gfx_v7_0_priv_reg_irq] *ERROR* Illegal
  register access in command stream` and fence-fallback timeouts on gfx + sdma
  rings. amdgpu is at 0000:00:01.0 (NOT under bpcie) so these errors suggest
  the AMDVI bus_token hack on bpcie is corrupting x86_vector_domain's
  allocation state for *non-Baikal* devices too. amdgpu fence completion
  isn't arriving, even though gfx_v7_0_priv_reg_irq itself appears to fire.

Why `info->handler` override doesn't reach the leaf isn't yet clear from log
alone. Hypothesis A: pci_msi_template's leaf uses a code path that ignores
info->handler (maybe its own `.msi_init` overrides what default would do).
Hypothesis B: handler IS installed at the leaf but MSI is delivered to a
different vector / virq than expected. Hypothesis C: hardware ISN'T actually
firing the MSI despite cap programming — Baikal needs an additional gate
register to enable interrupt delivery.

Architectural takeaway: **trying to fit Baikal's hardware demuxer into 6.x's
per-device MSI model may be the wrong shape**. The 5.4 model had bpcie's
domain be a *single shared domain* that all 8 functions referenced (via
fwnode-name lookup), with all subfunc hwirqs co-located in that one domain
so `irq_find_mapping(domain, initial_hwirq + i)` could resolve siblings.
6.x's per-device model splits each pdev into its own domain → demuxer's
sibling lookup pattern doesn't translate.

Two viable paths for v7:

  1. **Force legacy PCI MSI path**: remove `IRQ_DOMAIN_FLAG_MSI_PARENT` and
     `msi_parent_ops` from bpcie's domain. Kernel falls back to
     `pci_msi_legacy_setup_msi_irqs` which (with our `dev_set_msi_domain`
     install) routes through bpcie's existing `msi_domain_ops` directly —
     same as 5.4. But: 6.15's pci_msi_setup_msi_irqs only takes legacy if
     `!irq_domain_is_hierarchy(domain)` and msi_create_irq_domain always
     creates hierarchy. May need to manually rebuild the domain without
     hierarchy flag.

  2. **Single shared domain**: have bpcie create ONE domain instead of 8,
     install it on all 8 pdevs, and use the original 5.4 hwirq encoding
     (slot/func/subfunc with 0x1F suffix for shared mode). Demuxer's
     irq_find_mapping then works because all subfuncs are in the same
     domain.

(2) is closer to the working 5.4 design. Tracking as next-session priority
once user-side breaks.

Also: amdgpu regression in v6 means we need to gate the AMDVI bus_token
trick to apply *only when bpcie's domain is the parent for a Baikal child*,
not globally. Or find a less invasive way to satisfy x86's gating switch.

## Option B v7 — BaikalLove insights (2026-05-09 afternoon)

After surveying 30+ branches across rmuxnet/ps4-linux-12xx and
feeRnt/ps4-linux-12xx (index in `research/2026-05-09-bpcie-msi-shape-index.md`),
feeRnt's `x_exp__6.15.4-BaikalLove` turned out to be active engineering notes
on this exact problem: comments in source literally describe our diagnosis
path (`dev_set_msi_domain` "missing in 6.15-baikal; seems important",
`msi_create_irq_domain` vs `pci_msi_create_irq_domain` "the latter lacks a few
info flags", `handler_name = "edge"` "Seems important now").

v7 lifted three minimal targeted changes from BaikalLove:

1. `msi_create_irq_domain` → `pci_msi_create_irq_domain`. The PCI variant
   adds `MSI_FLAG_ACTIVATE_EARLY` (re-compose with real vector at alloc
   time, not at request_irq time), `MSI_FLAG_FREE_MSI_DESCS`,
   `MSI_FLAG_DEV_SYSFS`, `IRQCHIP_ONESHOT_SAFE`, sets
   `bus_token = DOMAIN_BUS_PCI_MSI`, and runs
   `pci_msi_domain_update_dom_ops/chip_ops` to fill PCI defaults.
2. `bpcie_msi_prepare`: `init_irq_alloc_info(arg, NULL)` +
   `arg->type = X86_IRQ_ALLOC_TYPE_PCI_MSI` (was `memset(arg, 0)` — wiped
   the alloc type field).
3. `bpcie_msi_domain_info`: add `.handler_name = "edge"`.

Boot result (full report:
`research/2026-05-09-v7-baikallove-result.md`, slice:
`uart-logs/2026-05-09_1436-v7-baikallove.log`):

  - ✅ amdgpu fence regression introduced in v6 is gone (v7 boots GPU
    cleanly).  v6's `DOMAIN_BUS_AMDVI` bus_token isn't what caused the
    regression — it was likely the missing `MSI_FLAG_ACTIVATE_EARLY` /
    chip ops setup that `pci_msi_create_irq_domain` provides.
  - ❌ `bpcie_handle_edge_irq` still fires 0 times.  Same as v3/v4/v5/v6.
  - All Baikal subfunctions still time out on completion interrupts
    (xhci ENABLE_SLOT, sdhci cmd, ata1 IDENTIFY, ICC pwrbutton).

v7 lifted one bug (`memset(arg, 0)`) and one regression (amdgpu), but the
fundamental wall is unchanged.  We have now comprehensively confirmed the
MSI infrastructure is set up correctly across the parent → bpcie →
x86_vector hierarchy:

- vectors are real (no 0xef spurious in second-wave activation),
- programmed to the right CPU LAPIC (`addr_lo=fee0X000`),
- bpcie_msi_init/write_msg fire,
- `init_dev_msi_info` propagates to child domains.

Yet no MSI fires through to `bpcie_handle_edge_irq`.

Three hypotheses for v8 to disprove with instrumentation:

  (A) The leaf irq_data's handler is silently overridden after we set
      `info->handler = bpcie_handle_edge_irq`.  Check by adding a `pr_info`
      to the standard `handle_edge_irq` and seeing if THAT fires for
      Baikal hwirq.
  (B) The hardware MSI fires but to a different vector or CPU than we
      expect.  Check by dumping `desc->irq_count` for Baikal virqs.
  (C) The hardware doesn't fire MSI at all — Baikal needs an additional
      enable register we're not writing.

v8 must instrument before changing more code.

Also added `scripts/dev/boot-capture.sh` (this commit) — records byte
offset of the rolling UART log at start, slices that excerpt at stop into
a clean named file under `checkpoint/uart-logs/` with non-printable bytes
sanitized to `?`.  Auto-prints a signal summary (counts of
`bpcie_handle_edge_irq`, `Command Aborted`, etc.) so post-boot analysis
doesn't require digging through 7+ MB of mixed-binary rolling log.  See
`scripts/dev/README.md` for usage.

## 2026-05-09 — Option D (v8): the bigger reframe

After all 7 Option B variants showed `bpcie_handle_edge_irq=0`, re-reading
v7 against feeRnt's `x_exp__6.15.4-BaikalLove` snapshot revealed the actual
problem.  Hypothesis (A)/(B)/(C) above were all wrong framings.  The real
answer is hardware-architectural:

**PS4 Baikal southbridge does MSI virtualization.** Child PCI funcs do NOT
fire MSI to LAPIC.  They write a Baikal-magic tuple (`addr=0xFEE00000`,
`data=<subfunc-index>`) that the southbridge intercepts on the HT link,
decodes, accumulates into `BPCIE_ACK_READ`, and converts into a single
real MSI fired on bpcie's (function-4 Glue) own vector pool.  The kernel
then dispatches `bpcie_handle_edge_irq`, which reads `BPCIE_ACK_READ` and
demuxes into per-subfunc handlers.

v1–v7 used `x86_vector_msi_compose_msg` which writes a real LAPIC vector
(e.g. `addr_lo=fee02000 data=0x20`).  The southbridge silently swallows
that — `0xFEE02000` ≠ its `0xFEE00000` sentinel, and `data=0x20` is out of
the subfunction-index range.  No LAPIC delivery.  No demuxer.  No driver
handler. ✗

The smoking gun was in our own v7 source the entire time:

```c
.irq_compose_msi_msg = x86_vector_msi_compose_msg,  // this seems kinda wrong
```

That comment was right.

**Option D fix**: faithful port of feeRnt's BaikalLove approach —
- Custom `bpcie_irq_msi_compose_msg` writing `addr_lo=0xFEE00000` +
  `data=irq_map[]-derived-index`.
- New `int irq_map[100]` field in `struct abpcie_dev`, tracking
  virq → subfunc-index.
- `bpcie_msi_init` populates next free slot; composer reads it back.
- Drop `IRQ_DOMAIN_FLAG_MSI_PARENT`, `msi_parent_ops`,
  `init_dev_msi_info`, AMDVI bus_token override.  Use the legacy 2-level
  (bpcie → x86_vector) MSI domain since 6.x still supports it for devices
  whose hardware doesn't speak the per-device MSI rework's assumptions.
- Keep `pci_msi_create_irq_domain` (BaikalLove uses it).
- Keep `dev_set_msi_domain` install (BaikalLove uses it).

See `checkpoint/docs/research/2026-05-09-option-d-thesis.md` for the
full architectural writeup.

This reframes 7 prior iterations: we were not on the wrong side of a
kernel bug or missing API.  We were wiring up a kernel API that the
hardware is fundamentally incompatible with.  Lesson for future Claude:
**when the kernel-side telemetry says everything looks healthy and yet
nothing works, suspect the silicon.**

## 2026-05-09 — Option E (v9): the routing+composer combo finally worked

Marrying v7's routing (parent flag + msi_parent_ops + AMDVI bus_token)
with v8's composer (`addr_lo=0xFEE00000` + irq_map[]-derived index)
produced a CLEAN MSI infrastructure.  All software signals green:

- `bpcie_irq_msi_compose_msg` × 80 (was 0 in all previous iterations)
- `bpcie_msi_init: registered virq` × 34 (irq_map populated)
- `bpcie_msi_write_msg` writes `addr_lo=fee00000` with monotonic
  per-virq subfunc indexes (xhci=0x20, sdhci=0x21, ...)
- `Spurious interrupt 0xef` count = 0 (vs 2 in v8 — every alloc
  routed through OUR domain, none leaked to default x86_vector)

Yet `bpcie_handle_edge_irq` STILL fires 0 times.  Because the failure
is no longer software-side: every kernel-side hypothesis is now ruled
out by direct positive evidence.  The southbridge is not firing its
own MSI to LAPIC in response to child device events — it's a hardware
enable bit that's missing.

The smoking gun has been in our own ps4-bpcie.c line 185 since day 1:
`//TODO: disable ht. See apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask`

PS4 Baikal southbridge sits behind a Hyper-Transport link.  Until
HT-style legacy IRQ delivery is disabled at the southbridge, MSIs
don't propagate.  The FreeBSD orbis driver has a function literally
named that — we've never implemented its equivalent.

5.4 works because... TBD.  Possibly some other init step leaves HT in
the right state by accident, OR 5.4's slower MSI activation path
doesn't trip the same gate.  v10 = research + implement HT disable.

**Lesson for future-Claude.**  When hardware-driver code has a TODO
comment naming a specific function from a vendor reference driver,
that comment is a treasure map — investigate it BEFORE assuming the
problem is somewhere else.  We spent 7 iterations debating Linux 6.2
MSI rework details when the actual blocker had a TODO marker that
no one reread until iteration 9.

## 2026-05-09 — Option F (v10): southbridge programming + a func extraction bug

Implemented the day-1 TODO (`apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask`)
as a faithful port of Aeolia's apcie_config_msi for Baikal.  bpcie_config_msi
ran 41 times without crashing, validating that BAR2 + 0x110000 is the
correct register block base.

But a bug in func/subfunc extraction:

```c
u32 func = (data->hwirq >> 5) & 7;  // WRONG at leaf level
```

The Baikal hwirq encoding `(slot<<8)|(func<<5)|subfunc` only exists at
the bpcie PARENT domain level (set in bpcie_msi_domain_set_desc into
arg->hwirq).  In 6.x's per-device MSI flow, the LEAF irq_data->hwirq
is just the per-device subfunction index (0..nvec-1).  Result: all
calls decoded `func=0` regardless of which device requested the MSI.

Bpcie's 32 own MSIs all programmed func=0 slots 0..31; xhci/sdhci/ahci
never got their slots programmed.  bpcie_handle_edge_irq still fires 0
because the southbridge's per-function logic for funcs 2/3/5/7 is
uninitialized.

**Lesson for future-Claude.**  When you write a function that depends on
how `irq_data->hwirq` is encoded at the level it runs at, EXPLICITLY
write down which level you expect data to be at, and verify against the
actual irq_domain hierarchy.  In modern (6.2+) per-device MSI:
- bpcie domain (parent): hwirq = full Baikal encoding
- per-device transient domain (leaf): hwirq = 0..nvec-1 within device

Driver write_msg / mask / unmask hooks all run at LEAF level.

## 2026-05-09 — v11/v12: cross-check sibling drivers BEFORE inventing

After v9-v11 spent three iterations building on a custom composer
(`bpcie_irq_msi_compose_msg` writing 0xfee00000+irq_map_index), I
re-read 5.4 Aeolia (the working baseline for this hardware family)
and found Aeolia uses the KERNEL'S DEFAULT compose_msg
(`irq_msi_compose_msg`), passing REAL LAPIC encoding into its
`apcie_config_msi` southbridge programming.

v9's custom composer came from feeRnt's `x_exp__6.15.4-BaikalLove`
branch — RESEARCH notes, not a confirmed working baseline.  I mistook
"the most actively-worked-on branch" for "the one that works".

**Lesson for future-Claude.**  When porting between PS4 chip families
(Aeolia/Belize/Baikal) or between kernel versions:
1. Always identify the LATEST KNOWN-WORKING baseline (5.4 Aeolia in
   our case — it boots and runs).
2. Cross-check architectural choices against THAT baseline before
   adopting innovations from research/experimental branches.
3. "Active maintenance" ≠ "tested working".  Research branches are
   often abandoned mid-experiment.
4. If the working baseline uses kernel defaults, START with kernel
   defaults — only diverge with concrete evidence the divergence is
   needed for the new platform.

The 4 KB binary size difference between v9 and v10 in the same
direction was a sign that adding code wasn't fixing the root cause —
worth staring at when iterating on a stuck problem.

## 2026-05-10 — v44: kexec into Linux leaves PS4 display PLL at zero

Long-running mental model for the 6.x HDMI bring-up was that PS4 boot
firmware programs HDMI for PS4 OS, ArabPixel kexecs into Linux, and
the GPU display state stays intact — so if Linux/amdgpu doesn't
clobber it, the bridge stays locked.  Refuted by v44.

v44 added a Liverpool short-circuit in `dce_v8_0_crtc_mode_set` that
dumps DCCG_PLL[0..3]_PLL_{REF,FB,POST}_DIV and PIXCLK[0..2]_RESYNC_CNTL
via pr_info, then skips every ATOM-driven mode_set call (set_pll,
set_dtd_timing, overscan_setup, scaler_setup) and only runs
do_set_base + cursor_reset.

Boot result (2026-05-10 14:54): all four PPLL banks read as
`ref=0x00000000 fb=0x00000000 post=0x00000000`.  PIXCLK1_RESYNC_CNTL
reads as 0x1, the other two as 0 — so MMIO access is fine; the zeros
in PPLL banks are real.  Display dark (expected — no clock).

Implications:
- The kexec handoff from PS4-OS firmware into our Linux kernel resets
  the display engine's PLL state to zero, even though the framebuffer
  scanout regs and PIXCLK routing survive.
- Linux/amdgpu MUST program the display PLL itself.  ATOM
  `AdjustDisplayPll` returning 0 (which is what triggers the v28
  fallback to `mode->clock`) is a separate symptom — the PS4 VBIOS
  ATOM tables for display PLL appear to be stub.
- v33 "skip ATOM" + v44 "preserve BIOS state" were never going to
  work — neither programs the PLL, but PS4's PLL is unprogrammed at
  Linux entry, so both leave it at zero.
- Whether ATOM `SetPixelClock` (a different table from
  `AdjustDisplayPll`) writes the PLL on PS4 is still untested.  Could
  be tested with: run set_pll + dump PPLL after.  Not chosen as the
  next iteration — user opted for direct manual PLL programming
  instead (cheaper iteration count).

Lesson for future-Claude.  When a "preserve hardware state" hypothesis
is in play, the very first diagnostic should be: dump that state and
verify it matches the hypothesis BEFORE designing a patch around it.
v44 was framed as a fix, but its real value was the dump.  The dump
showed the hypothesis was wrong.  If we'd run the dump first as a
pure diagnostic patch (no skip-ATOM logic), we'd have moved to
"manual PLL programming" one iteration sooner.

Also: register dumps are cheap. Add them generously when investigating
hardware mysteries — every value either confirms a hypothesis (move
on) or refutes one (also useful).

## 2026-05-10 — v45: writes to mmDCCG_PLL_* silently dropped; the assumed PLL registers are probably wrong

After v44's "PPLL=0 across all four banks" finding, v45 added direct
WREG32 programming with hardcoded 1080p60 dividers (ref_div=1
fb_int=11 fb_frac=14 post=8) for all four `mmDCCG_PLL[0..3]_*`
register banks, packed per the `VGA*_PPLL_*` bit layout in
`dce_8_0_sh_mask.h`.

Boot result: POST-program read shows IDENTICAL all-zero values to
PRE-program read. WREG32 returns no error but the registers don't
store the writes.

Three new realizations that change the model of the problem:

1. **No code in either 5.4-baikal (working) or 6.x-baikal (broken)
   directly writes to `mmDCCG_PLL[0..3]_*`.** The 5.4 baseline
   produces full HDMI without anyone in-kernel touching these
   registers. So they're probably not the actual display PLL
   on Liverpool — ATOM SetPixelClock on 5.4 must either write
   different registers, or write these via some access path
   that hits hardware differently than direct WREG32.

2. **amdgpu has no PLL indirect-access infrastructure.**
   `RREG32_PLL`/`WREG32_PLL` are referenced inside `WREG32_PLL_P`
   macro but never #defined in amdgpu source. radeon driver
   has `pll_rreg`/`pll_wreg` callbacks but for CIK they're
   set to `radeon_invalid_rreg`/`_wreg` (only R100 cards used
   them). So "PLL needs indirect access" is not the issue.

3. **WREG32 to the DCCG block IS valid in this codebase** —
   `dce_v8_0.c:1537-1539` does `WREG32(mmDCCG_AUDIO_DTO_*, ...)`
   for audio clock setup, register offsets right next to ours.
   So the MMIO path reaches DCCG hardware. Our PPLL writes
   specifically are being rejected by something at the hardware
   level on those particular register addresses, OR those
   addresses are unused/aliased to ground on Liverpool.

Lesson for future-Claude: when writing manual register programmers
for hardware you don't have authoritative docs for, the very FIRST
test should be "does my WREG32 land?". If POST-write read != value
written, stop programming further and figure out why before
guessing more values. v45 wrote 12 register writes in one shot
and learned nothing from each individual write — a single
write-then-read for ONE register would've told us "writes drop
silently" with the same boot cost. Generalize: when programming
hardware, instrument the smallest possible step and verify it
works before scaling up the operation.

Also lesson: I deprioritized the multi-agent ATOM IIO trace
recommendation in favor of "let's just try writing values" because
the trace patch is bigger work. v44/v45 cost two boots and a
half-day of dead-end analysis. The trace would have cost one boot
and answered the actual question (which registers does ATOM target
when it runs SetPixelClock on PS4). Diagnostic-first beats
fix-first when you don't even know what the right fix targets.


# 2026-05-10 evening — HDMI display fix, PS4 6.x-baikal (v60)

**Root cause:** PS4 firmware leaves the internal GPU→MN864729 DP link
already trained with per-lane voltage swing / pre-emphasis values not
derivable from VBIOS object info. Linux's standard DPMS_OFF/ON path
calls `setup_dig_transmitter(DISABLE)` then `setup_dig_transmitter(ENABLE)`,
which writes ATOM v5 args including `ucDPLaneSet=0` (default swing
0/preemph 0). ATOM bytecode pushes those values into UNIPHY hardware,
overriding the firmware-trained per-lane state. The receiver immediately
loses lock. PS4 bridge doesn't speak DPCD, so kernel link training
(patch 0006: bare return) cannot retrain.

**Fix:** skip both `setup_dig_transmitter(DISABLE)` and
`setup_dig_transmitter(ENABLE)` for `CHIP_LIVERPOOL/CHIP_GLADIUS` DP
encoders during modeset. Patches 0031 (v59) and 0032 (v60). Leave the
firmware-trained PHY completely untouched. CRTC, PPLL (PPLL2), DIG
encoder (SETUP/PANEL_MODE/DP_VIDEO_OFF/DP_VIDEO_ON), framebuffer, and
bridge programming all run normally.

**The bisect that found it:** v55 (chunk-split bridge cq) split the
monolithic 2.97s `cq_wait_*` timeout into three separate timeouts,
revealing chunks B and C are *always* tolerated baseline (~450ms each
in both BIOS-state and post-modeset cycles), while chunk A (`0x60f8/0xff`
DP RX lane lock) flips from passing fast (~30ms, `0x60f8=0xff`) at boot
to timing out at ~600ms (`0x60f8=0x0f`) post-modeset. This reframed
the problem from "bridge needs us to drive it" to "we broke its
already-locked receiver".

v58 added `ps4_bridge_probe_lane_status(tag)` calls between every modeset
step. In one boot it pinpointed `setup_dig_transmitter(DISABLE)`:
`f8: 0xff → 0x9f` exactly at action=0. v59 (skip DISABLE) preserved
lock through DP_VIDEO_OFF/SETUP/PANEL_MODE but `setup_dig_transmitter(ENABLE)`
then flipped `f8: 0xff → 0x0f`. v60 (also skip ENABLE) preserved lock
end-to-end including DP_VIDEO_ON. Bridge passes; HDMI lights.

## Lessons

1. **"Preserve firmware state" is a real strategy on consoles.** PC DP
   assumes hot-plug retraining; consoles often pre-train everything in
   firmware. If standard DPMS_OFF/ON doesn't work, ask: "what is the
   firmware doing that we're undoing?" before assuming "what is the
   firmware not doing that we need to do?".

2. **Sub-step bisection beats blind reverts when ambiguity is multi-axis.**
   v52-v57 wasted iterations trying combinations of "add this", "remove
   that". v58's intra-step probe gave a definitive answer in one boot
   because it sampled state at every step boundary.

3. **Splitting monolithic timing measurements is high-value.** v55
   chunking the bridge cq main seq made the chunk-A vs chunks-B/C
   distinction visible. Without that split, every iteration looked like
   "still 2.97s timeout" and nothing was learned. The same insight
   pattern probably applies elsewhere: any time you measure a single
   wall-clock duration over a multi-step operation, try splitting it.

4. **Sometimes the diagnostic patch is the breakthrough.** v55 and
   v58 don't change behavior (just visibility), but they're what
   actually unblocked the fix. Resist the temptation to keep guessing
   when one more diagnostic boot would resolve the ambiguity.

5. **Hermes' iterative consultation worked well.** Multi-agent advice
   at v55→v56→v57→v58→v59→v60 each step accelerated decisions:
   - When to escalate to bridge-side instrumentation
   - When to bisect by reverting suspects
   - When to do step-by-step probing instead of guessing
   - Recognizing v54 (TPS pulse) was the wrong premise after v55 data.

6. **Five-agent synthesis (research/ideas/) was useful even though
   only one was right.** The Kimi `dp_clock=0` hypothesis from
   `2026-05-10-kimi-dp-clock-zero.md` was the foundation: it identified
   that downstream consumers were reading 0 from `dig_connector`
   fields. v47 (local floor) implemented the spirit; v52 (connector
   floor) implemented the letter. v59/v60 then extended the
   "preserve firmware state" model. Without the multi-agent synthesis
   we might still be chasing PPLL register-set theories.

Full analysis chain: `checkpoint/docs/research/2026-05-10-v46-...md`
through `2026-05-10-v60-...md`. The v60 result file is the canonical
write-up of the breakthrough.

## v70 — UVD/VCE registration works, but there's a second gate (2026-05-11)

CLAUDE.md's "v16 working config" note had said `liverpool_uvd.bin` /
`liverpool_vce.bin` were shipped in initramfs but the IP blocks
themselves were *commented out* in `cik_set_ip_blocks` for CHIP_LIVERPOOL
and CHIP_GLADIUS. v70 simply uncommented the four `ip_block_add` calls
in patch 0001 (lines 788–789 and 806–807).

What worked: the IP blocks register correctly. UART confirms
`detected ip block number 6 <uvd_v4_2>` and `7 <vce_v2_0>` at t=7.547s.
HDMI bridge programming also still ran fine (chunks A/B/C all rc=20,
elapsed times within v60 envelope).

What broke: `[drm:amdgpu_device_init.cold] *ERROR* sw_init of IP block
<uvd_v4_2> failed -22` at t=9.740s. Whole amdgpu probe unwound,
no fbcon → blank HDMI even though the bridge was correctly programmed.

Root cause: `amdgpu_uvd_sw_init` (`drivers/gpu/drm/amd/amdgpu/amdgpu_uvd.c:194`)
and `amdgpu_vce_sw_init` (`amdgpu_vce.c:105`) both have a
`switch (adev->asic_type)` selecting the firmware filename, and the
CIK-class arm covers Bonaire/Kabini/Kaveri/Hawaii/Mullins but **not**
CHIP_LIVERPOOL/CHIP_GLADIUS. Falls through to `default: return -EINVAL`.
The shipped firmware blobs are never even requested.

**Lesson: when porting a new chip into amdgpu, registering the IP
block is necessary but not sufficient.** Most IP-block code paths
(uvd, vce, sdma, gfx) do an asic_type → firmware-name lookup early
in `sw_init`. Add cases there *at the same time* you register the
block, or expect a `-EINVAL` failure that masquerades as a generic
"init failed" cascade.

v71 candidate fix is in
`patches/6.x-baikal/0300-gpu-liverpool/0033-amdgpu-uvd-vce-liverpool-firmware-name.patch`
— adds `case CHIP_LIVERPOOL: case CHIP_GLADIUS: fw_name = "amdgpu/liverpool_{uvd,vce}.bin"; break;`
to both switches, plus the matching `#define` and `MODULE_FIRMWARE` macros.
75 lines total, doesn't touch any other codepath.

**Second lesson: blank HDMI ≠ HDMI patch regression.** The v60 bridge
patches all ran exactly as expected in v70. The display went dark
because probe failed *after* bridge enable, before fbcon could bind.
If a future iteration breaks display with the bridge logs still
clean, look for an `amdgpu_device_ip_init` failure in dmesg, not a
DP-state regression.

See `checkpoint/docs/research/2026-05-11-v70-uvd-vce-result.md` for
full signal counts, boot timing, and v71 expected-outcome matrix.
