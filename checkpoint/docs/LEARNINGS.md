# What we learned getting PS4 Linux to boot

A timeline of dead ends and wins from the 2026-05-06 session, kept here so we don't relearn the same things.

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

### Don't add `keep_bootcon` on this hardware

We tried `keep_bootcon` to extend earlycon past the regular console handover so we'd get full-boot UART. **It crashes xhci_aeolia at ~57 seconds.** The BPCIe glue device parents both the UART and the xhci controller (`00:14.7`); constant earlycon writes to UART MMIO appear to overload the bus and the xhci host eventually goes into "not responding" → "HC died" → USB rootfs disappears → ext4 errors → systemd cascade-fails.

So the **stable** bootargs is **earlycon without `keep_bootcon`**:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

Behavior:
- 0.000s — earlycon active, UART logs every printk
- ~1.0s — `console=tty0` registers (HDMI fbcon), earlycon retires automatically (`bootconsole [uart8250] disabled` in dmesg)
- ~1.0s onward — kernel output goes to HDMI; UART silent; xhci stays alive

`checkpoint/docs/uart-boot-capture-ttyS0E000.log` is a real capture of the ~135-line UART window for reference.

### When the kernel boot fails silently and the screen shows just `_`

That underscore is the firmware's leftover cursor. Here's the rundown:
- Just `_`, no UART, no rebooting → kernel jumped, hung in *very* early init before any console came up. Earlycon should give us one or more lines before this happens. If we see literally nothing and `_` stays put, the kernel jumped to bad memory or triple-faulted before earlycon could initialize.
- Just `_` + PS4 reboots back to firmware in ~milliseconds → triple-fault. Used to be every kexec attempt with old per-firmware payloads; v24b fixed this.

## What's still on the to-do list

- Investigate why our self-built bzImages hang. Suspect: Clang 22 / GCC 15 toolchain regressions for old kernels. Prove it by rebuilding 5.4 with Clang-14 and seeing if it boots.
- Layer kernel modules onto the deeWaardt rootfs so we get WiFi (mt7668) and the rest. Need to either rebuild from feeRnt's source (so version matches `5.4.247-neocine-1.1`, no `-dirty` suffix) or convince feeRnt to ship a modules tarball in their release.
- Retry our 6.x build with v24b payload — earlier failures were against the old per-firmware payload, which always triple-faulted regardless.
- Cap Mesa at 25.1 in the rootfs (deeWaardt's tarball is already pinned, but watch out on first `pacman -Syu`).
