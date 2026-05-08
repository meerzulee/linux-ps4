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
