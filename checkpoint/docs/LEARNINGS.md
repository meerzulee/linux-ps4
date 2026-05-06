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

## What's still on the to-do list

- Investigate why our self-built bzImages hang. Suspect: Clang 22 / GCC 15 toolchain regressions for old kernels. Prove it by rebuilding 5.4 with Clang-14 and seeing if it boots.
- Layer kernel modules onto the deeWaardt rootfs so we get WiFi (mt7668) and the rest. Need to either rebuild from feeRnt's source (so version matches `5.4.247-neocine-1.1`, no `-dirty` suffix) or convince feeRnt to ship a modules tarball in their release.
- Retry our 6.x build with v24b payload — earlier failures were against the old per-firmware payload, which always triple-faulted regardless.
- Cap Mesa at 25.1 in the rootfs (deeWaardt's tarball is already pinned, but watch out on first `pacman -Syu`).
