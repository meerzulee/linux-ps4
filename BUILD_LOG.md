# PS4 Linux Kernel Build Log

## Target Hardware
- **Console:** PS4 Slim
- **Southbridge:** Baikal B1 (0x30201)
- **WiFi/BT:** MediaTek MT7668

---

## Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| Targets | 5.4-baikal, 6.x-baikal | Multi-target build system |
| 5.4 patch series | 13 patches, 278 files, 224k lines | 100% coverage of feeRnt 5.4.247-baikal vs vanilla v5.4.247 (+ Clang 22 -mhard-float fix) |
| 5.4 patches dry-run | ALL APPLY CLEAN | Verified against vanilla v5.4.247 |
| 5.4 build | **SUCCESS** | bzImage 7.7MB — kernel `5.4.247-neocine-1.1-dirty`, Clang 22 |
| 5.4 boot test (our build) | **FAILS** at kexec | Hangs immediately. Suspect Clang 22 toolchain regression on 5.4. |
| 5.4 boot test (feeRnt prebuilt Clang-14) | **WORKS** | Used as the working baseline. |
| 6.x patch series | 15 patches, 100 files, 11k lines | crashniels' 6.15-baikal split into per-subsystem patches + bpcie-icc fix + feeRnt's xhci-Baikal-shutdown fix |
| 6.x patches dry-run | ALL APPLY CLEAN | Sequential apply against vanilla v6.15.4 |
| 6.x build | **SUCCESS** | bzImage 9.2MB — kernel `6.15.4-Baikal_TESTING_crashniels-dirty`, GCC 15 |
| 6.x boot test (our build) | **FAILS** at kexec | Hangs identically to our 5.4. Same suspect (toolchain) — needs retest with v24b payload. |
| 6.x WiFi (mt7668) | NOT YET PORTED | See `patches/6.x-baikal/9000-todo/README.md` |
| UART access | YES | Serial console wired to PS4. Note: persistent-UART payload's hooks die at kexec; UART silent until in-kernel ps4-bpcie-uart driver registers ttyS0 late in boot. |
| End-to-end Linux boot | **WORKS** | feeRnt 5.4 prebuilt + v24b payload + better-initramfs + deeWaardt rootfs → systemd up, SSH reachable. See `checkpoint/`. |

---

## 2026-05-06 — UART unlocked via earlycon

Building on the morning's working boot, tracked down why Linux UART was silent post-kexec. Two findings:

1. **`ps4-bpcie-uart.c` registers ports without `port.type`** → kernel sets `PORT_UNKNOWN` → 8250 console layer refuses any I/O on those ttySN devices, including writes. Confirmed: `stty -F /dev/ttyS4 …` errored with EIO. Workaround: bypass the regular driver path with `earlycon=uart8250,mmio32,<addr>,…` which writes directly to MMIO from the printk path.

2. **The kernel registered the wrong BPCIe UART as the first ttyS line.** `BPCIE_NR_UARTS=2`. UART0 is at BAR2+`0x10E000` = `0xC890E000`, UART1 is at BAR2+`0x10F000` = `0xC890F000`. Linux's ttyS4 was UART1, but the user's physical UART cable is wired to **UART0**. Confirmed by writing sentinel bytes to both via `/dev/mem` (`scripts/uartprobe.py`); only `0xC890E000` reached the cable.

3. **`keep_bootcon` crashes xhci_aeolia at ~57 s** on this hardware — constant earlycon writes saturate the BPCIe bus, the xhci host (also behind `00:14.4` glue) goes "not responding" → USB rootfs disappears → ext4 errors → systemd cascade-fails. Don't use `keep_bootcon`. Earlycon retires when `console=tty0` registers (~1 s), HDMI fbcon takes over from there.

Final bootargs:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

Result: ~1 s of full UART boot capture (decompression → BIOS-e820 → ACPI → CPU bring-up → memory init → IRQ alloc → fbcon switch), then HDMI. Sample capture committed at `checkpoint/docs/uart-boot-capture-ttyS0E000.log` (135 lines).

Iteration setup that drops the unplug-USB step entirely: bootargs and bzImage live on the FAT32 (`sda1`); from running Linux we mount `/dev/sda1` over SSH, edit the file, `sudo systemctl reboot`, user re-launches `linux-1024mb.bin` via PSFree, kernel boots with the new cmdline. Whole loop ~1 minute.

Same SSH-driven workflow now lets us swap bzImages on demand for 6.x port experiments — see `9000-todo`.

---

## 2026-05-06 — first successful end-to-end Linux boot

After multiple failed boot attempts the actual blocker was finally pinned down. Working combo, captured in `checkpoint/`:

- bzImage = feeRnt's prebuilt `5.4.247-neocine-1.1` (Clang-14 build, 9.18 MB)
- initramfs = better-initramfs External HDD variant from `DionKill/ps4-linux-tutorial`
- payload = `ArabPixel/ps4-linux-payloads` v24b, `linux-1024mb.bin`
- rootfs = deeWaardt's "Arch - Baikal Ed." tarball (Mesa 25.1, **v2-baseline binaries**)
- bootargs = `console=tty0 console=ttyS0,115200n8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on`

**The decisive findings:**

1. **Old per-firmware ArabPixel payloads (`payload-1200-Xgb-baikal.bin`) triple-fault every kexec.** Five attempts, identical instant reboot back to PS4 secure-loader. Switching to the v24b unified payload fixed the kexec hand-off and got us a real kernel boot for the first time. The v24b payload reads bzImage/initramfs/bootargs/vram from `/mnt/usb0/`, `/mnt/usb1/`, `/data/linux/boot/`, or `/user/system/boot/` (in that priority order); USB wins if present.

2. **Our self-built bzImages don't boot.** Both the 5.4 (Clang 22) and the 6.x (GCC 15) hang at kexec in exactly the same way as the broken-payload runs did. feeRnt's prebuilt Clang-14 5.4 boots fine with the same payload and same USB. Strong suspicion is modern toolchain regressions on old kernels — feeRnt explicitly chose LLVM-14 in their release notes "as it seems the most compatible for Kernel 5.4.247". To confirm, we'd need to rebuild with Clang-14. Deferred.

3. **`earlyprintk=serial,ttyS0,115200` is poison on PS4.** Targets the legacy 8250 at I/O port `0x3F8`. There's no such port on PS4 — the Baikal UART is MMIO from a runtime-resolved PCI BAR. The kernel hangs immediately on first early-print. We'd had this in our bootargs across multiple attempts, masking the loader-level issues. Always strip earlyprintk= for PS4.

4. **PS4 Jaguar APU is roughly x86-64-v2 + AVX1, NOT v3.** Confirmed from FreeBSD bootloader CPU print (`Features2=0x36d8220b` — AVX yes, AVX2/BMI/FMA/LZCNT no). Modern Arch is `x86-64-v3` baseline. CachyOS even more aggressive. So `pacstrap` from the dev host (CachyOS) into the PS4 ext4 produced a rootfs whose systemd executes AVX2 opcodes on first run → SIGILL → `Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b`. Fix: replace pacstrap'd Arch with deeWaardt's v2-compatible Baikal tarball. **Never pacstrap from a v3 host into a PS4 rootfs.**

5. **UART silence post-kexec is expected.** The persistent-UART payload hooks the FreeBSD UART driver. Linux's kexec stub sets up its own page tables and that hook is gone the moment we jump into bzImage. UART comes back when the in-kernel `ps4-bpcie-uart` 8250-glue registers ttyS0 — but that's late. Use `console=tty0` for early-boot visibility on HDMI in the meantime.

6. **`fstab` from `genfstab` is unwanted.** It baked our host's UUIDs into the PS4 rootfs which would mismatch on every relabel. The `install-deewaardt-rootfs.sh` script writes a minimal fstab with just `LABEL=psxitarch / ext4` and lets systemd auto-mount the rest.

**Result:** kernel boots → better-initramfs runs → switch_root into deeWaardt's rootfs → systemd reaches multi-user → SSH reachable on `192.168.50.125` as `ps4`/`ps4`.

**Checkpoint files at `checkpoint/`** with sha256 hashes in `SHA256SUMS`. Reproducible boot guide at `checkpoint/README.md`. Detailed lessons at `checkpoint/docs/LEARNINGS.md`.

---

## 2026-05-04 — 6.x-baikal builds (first try!)

After landing the 5.4 baseline, the 6.15.4-baikal port came together cleanly:

- Forward-port strategy: rather than hand-port each 5.4 patch to 6.x, we
  diffed crashniels' `ps4-linux-6.15.y-baikal` (HEAD `b3b6b1e4f`) against
  vanilla v6.15.4 (commit `e60eb4415`). crashniels has already done the
  heavy 5.4 → 6.x forward-port, including: Liverpool support added to
  `drivers/gpu/drm/radeon/` (legacy path) on top of amdgpu, amdkfd CIK
  quirks, the MSI subsystem refactor (`arch/x86/kernel/apic/msi.c` →
  `drivers/pci/msi/irqdomain.c` + `kernel/irq/irqdomain.c`), and the
  iommu directory move to `drivers/iommu/amd/`.
- Generated 13 per-subsystem patches via `scripts/generate-6.x-patches.sh`,
  mirroring the structure of `patches/5.4-baikal/`. 100/100 file coverage.
- Added 2 hand-curated patches: our `ps4-bpcie-icc` pointer-type fix
  (now a real patch, not the build.sh sed hack), and feeRnt's
  `xhci-aeolia` Baikal-shutdown fix (commit `b0969f7d101f`).
- All 15 patches apply sequentially against vanilla v6.15.4 — verified
  by dry-run before the actual build.
- Build #1 succeeded on first try with **GCC 15** (no toolchain issues
  this time, unlike the 5.4 build which needed Clang). 9.2MB bzImage.

Outputs in `output/6.x-baikal/`:
- `bzImage` — 9.2 MB
- `config` — 123 KB
- `System.map` — 4.4 MB
- `version.txt` — `6.15.4-Baikal_TESTING_crashniels-dirty`

**Known gap:** mt7668 (mt76x8 vendor) WiFi/BT driver is not in any 6.x
reference tree. The 6.x kernel boots without WiFi for now. Full
write-up in `patches/6.x-baikal/9000-todo/README.md`.

---

## 2026-05-04 — 5.4.247-baikal builds!

Build #5 succeeded after 4 failed attempts:

1. **Build #1**: died silently after first patch — `((PATCH_COUNT++))` returns 0 with `set -e` enabled, killed script. Fixed by switching to `PATCH_COUNT=$((PATCH_COUNT + 1))`.
2. **Build #2**: same as #1 (didn't notice `tee` masking exit code).
3. **Build #3**: died at `drivers/base/firmware_loader/builtin` because `CONFIG_EXTRA_FIRMWARE` lookup pointed at `/lib/firmware` which doesn't have the MT7668 blobs. Fixed: copied feeRnt's `extra_firmware/` (9 files, 928KB) into project `firmware/`, and changed `CONFIG_EXTRA_FIRMWARE_DIR` to absolute project path.
4. **Build #4**: died compiling `drivers/gpu/drm/amd/display/dc/calcs/dcn_calcs.o` with `clang: error: unsupported option '-mhard-float'`. Clang 16+ removed this flag; feeRnt's CI pins Clang 14. Fixed: added `0300-gpu-liverpool/0002-amdgpu-dc-drop-mhard-float-for-modern-clang.patch` stripping `-mhard-float` from 5 DC Makefiles (calcs, dml, dsc, dcn20, dcn21). The flag is a no-op on modern x86_64 Clang anyway.
5. **Build #5**: SUCCESS. 13 patches applied cleanly, full kernel + modules built with Clang 22 + LLD 22.

Outputs in `output/5.4-baikal/`:
- `bzImage` — 7.7 MB
- `config` — 112 KB (the resolved .config)
- `System.map` — 3.9 MB
- `version.txt` — `5.4.247-neocine-1.1-dirty`

---

## 2026-05-04 — Multi-target restructure

- Reorganized repo into per-target patch series (`patches/5.4-baikal/`, `patches/6.x-baikal/`)
- Per-target env files in `targets/<name>.env` define base repo, ref, config, series
- `build.sh -t <target>` selects target; default is `5.4-baikal`
- Cloned 6 reference repos into `tmp/` (~9GB)
- Generated complete 5.4-baikal patch series from feeRnt 5.4.247-baikal vs vanilla v5.4.247
- Strategy: build 5.4 baseline first (known-working), then forward-port to 6.x using crashniels' 6.15-baikal as merge base. UART available so we'll see actual boot output.

---

## Build Attempt #1

**Date:** 2024-01-14
**Base:** crashniels/linux `ps4-linux-6.15.y-baikal`
**Branch/Commit:** b3b6b1e4f (Add baikal checks)

### Patches Applied
```
(none - using crashniels base which already has PS4/Baikal patches)
```

### Config Changes
- Base: `config/config.baikal-b1` (copied from crashniels)
- Fragments applied:
  - `config/fragments/mt7668.config` - Enable MediaTek MT7668 WiFi/BT

### Build Result
- Status: FAILED - missing `bc` dependency
- Output: -
- Errors: `/bin/sh: line 1: bc: command not found`
- Fix: `sudo pacman -S bc`

### Test Result
- Booted: -
- Display: -
- WiFi: -
- Notes: -

---

## Build Attempt #2

**Date:** 2024-01-14
**Base:** crashniels/linux `ps4-linux-6.15.y-baikal`
**Branch/Commit:** b3b6b1e4f

### Patches Applied
```
(none - using crashniels base)
```

### Config Changes
- Base: `config/config.baikal-b1`
- Fragments: `config/fragments/mt7668.config`

### Build Result
- Status: FAILED - type errors in ps4-bpcie-icc.c
- Output: -
- Errors:
```
drivers/ps4/ps4-bpcie-icc.c:292:35: error: passing argument 1 of 'ioread32' 
makes pointer from integer without a cast [-Wint-conversion]
  292 |         value_to_write = ioread32(addr) | 1;
                                          ^~~~
drivers/ps4/ps4-bpcie-icc.c:286: u32 addr; should be void __iomem *addr;
```

### Test Result
- Booted: -
- Display: -
- WiFi: -
- Notes: -

---

## Build Attempt #3

**Date:** 2026-01-14
**Base:** crashniels/linux `ps4-linux-6.15.y-baikal`
**Branch/Commit:** b3b6b1e4f
**Kernel Version:** 6.15.4

### Patches Applied
```
# Applied via sed in build.sh (patch file had format issues)
drivers/ps4/ps4-bpcie-icc.c: u32 addr -> void __iomem *addr
```

### Config Changes
- Base: `config/config.baikal-b1`
- Fragments: `config/fragments/mt7668.config`, `config/fragments/debug.config`

### Build Result
- Status: SUCCESS
- Output: `output/bzImage` (9.6MB)
- Kernel: 6.15.4-gb3b6b1e4fe87-dirty

### Test Result #1 (old initramfs)
- Booted: NO
- Display: BLACK SCREEN
- WiFi: -
- Notes: Used old initramfs from 2021 (whitehax0r) - incompatible with 6.x kernel

### Test Result #2 (minimal initramfs) - PENDING
- initramfs: `output/initramfs-minimal.cpio.gz` (688KB)
- Built with static busybox 1.35.0
- Will show debug output on screen

---

## Patches Inventory

### From crashniels 6.15-baikal (already integrated)
These are already in the base kernel:
- [x] PS4 platform detection (`arch/x86/platform/ps4/`)
- [x] Baikal southbridge support (`drivers/ps4/baikal.h`)
- [x] APCIE driver (`drivers/ps4/ps4-apcie.c`)
- [x] BPCIE driver (`drivers/ps4/ps4-bpcie.c`)
- [x] Liverpool GPU support (`drivers/gpu/drm/amd/amdgpu/ps4_bridge.c`)
- [x] AHCI modifications
- [x] XHCI/USB support
- [x] MT7668 Bluetooth enable (commit c371e772a)

### Patches to potentially add (from patches/series)
```
# Currently all commented out - crashniels base may be sufficient
# Uncomment as needed based on testing

# 0100-southbridge/
# 0200-graphics/
# 0300-storage/
# 0400-wifi-bt/
# 0500-input/
# 0600-system/
```

### Reference Repos Cloned
- [x] `tmp/crashniels-6.15` - Base kernel
- [x] `tmp/feeRnt-5.4.247-baikal` - MT7668, blackscreen fixes
- [x] `tmp/feeRnt-5.15-belize` - WiFi SDIO fixes
- [x] `tmp/whitehax0r-5.4-baikal` - Baikal syscon reference
- [x] `tmp/ps4boot-5.3-baikal` - Original Baikal patches

---

## Config Tracking

### config/config.baikal-b1
- Source: `tmp/crashniels-6.15/config`
- Copied: 2024-01-14

### config/fragments/mt7668.config
Key options enabled:
```
CONFIG_WLAN_VENDOR_MEDIATEK=y
CONFIG_MT76_CORE=m
CONFIG_MT76_SDIO=m
CONFIG_MT7615_COMMON=m
CONFIG_MT7663_USB_SDIO_COMMON=m
CONFIG_MT7663S=m
CONFIG_BT_MTKSDIO=m
```

---

## USB Setup

- **Device:** /dev/sda (128GB DataTraveler 3.0)
- **Partitions:**
  - /dev/sda1: FAT32, 100MB, label: PS4BOOT
  - /dev/sda2: EXT4, ~115GB, label: psxitarch

### Rootfs
- **Type:** Arch Linux (Docker-created)
- **File:** `output/ps4linux.tar.xz` (1.5GB)
- **Credentials:** ps4/ps4, root/root

### Boot Files
- `bzImage` - 9.6MB (kernel 6.15.4)
- `initramfs.cpio.gz` - OLD: whitehax0r 2021 (3.9MB) - INCOMPATIBLE
- `initramfs-minimal.cpio.gz` - NEW: custom built (688KB) - TESTING
- `bootargs.txt` - `initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw loglevel=7 debug`

---

## Notes

### Key Findings
1. crashniels 6.15-baikal already has most PS4/Baikal patches integrated
2. MT7668 WiFi driver code exists but was disabled in config
3. Our config fragment enables MT7668 support

### Potential Issues to Watch
1. Blackscreen - may need display timing patches
2. Fan control - critical for hardware safety
3. WiFi detection - MT7668 SDIO initialization

---

## History

### 2026-01-14 (continued)
- Build #3 SUCCESS - kernel 6.15.4 built (9.6MB)
- Test #1 FAILED - black screen with old 2021 initramfs
- Created minimal initramfs with busybox (688KB)
- **Next:** Test #2 with new initramfs

### 2026-01-14
- Project structure created
- Reference repos cloned
- Config files prepared
- Arch Linux rootfs created (1.5GB)
- initramfs downloaded (whitehax0r 2021 - later found incompatible)
- USB formatted (FAT32 + EXT4)
- Build #1 FAILED - missing bc dependency
- Build #2 FAILED - bpcie-icc type errors
- Added sed fix to build.sh for bpcie-icc
