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
| 6.x boot test (our build) | **WORKS, bpcie cascade fixed** (2026-05-08, 3rd boot) | With `0004-ps4-bpcie-make-uart-failure-non-fatal.patch` applied: bpcie_probe returns 0, xhci-aeolia/sdhci/Belize-SATA-PHY all probe successfully, ICC init runs, kernel reaches `/init` at 54.95 s. Three new blockers prevent rootfs lookup: xhci `Error while assigning device slot ID: Command Aborted`, ahci -ENOMEM, mmc0 cmd timeout. See "2026-05-08, 3rd boot" entry. |
| 6.x WiFi (mt7668) | NOT YET PORTED | See `patches/6.x-baikal/9000-todo/README.md` |
| UART access | YES | Serial console wired to PS4. Note: persistent-UART payload's hooks die at kexec; UART silent until in-kernel ps4-bpcie-uart driver registers ttyS0 late in boot. |
| End-to-end Linux boot | **WORKS** | feeRnt 5.4 prebuilt + v24b payload + better-initramfs + deeWaardt rootfs → systemd up, SSH reachable. See `checkpoint/`. |

---

## 2026-05-08 (3rd boot, ~22:25) — bpcie cascade fixed; new blockers in xhci / ahci / sdhci

After writing `patches/6.x-baikal/0200-ps4-drivers/0004-ps4-bpcie-make-uart-failure-non-fatal.patch` (5-line change to `bpcie_probe` to demote UART init failure to a warning), rebuilt at 22:17 and installed onto the USB at 22:25 (kernel 9794560 B). Booted via ArabPixel v24b with the existing `6.x-diagnostic` bootargs (`keep_bootcon`, `initcall_debug`, `8250.nr_uarts=0`, no `console=ttyS0`).

**The new patch fires exactly as written**:

```
[    4.591198] baikal_pcie 0000:00:14.4: UART init failed (-5); continuing without serial console
```

**bpcie_probe completes for the first time on 6.x** (`probe of 0000:00:14.4 returned 0 after 296013 usecs`). Every downstream PS4 driver that gates on `apcie_status() == 1` now probes:

- `xhci_aeolia` (0000:00:14.7) — probes fully. Belize SATA PHY init runs to completion (`PHY SET GEN3`, trace length 6). Inline AHCI claims 6 Gbps, 32 cmd slots, 1 port. 4 USB buses registered (1, 2, 3, 4). USB 3.0 SuperSpeed.
- `sdhci-pci` (0000:00:14.3) — finds mmc0 ADMA controller `[104d:90da]`, probe returns 0.
- `bpcie_icc_init` runs through cleanly (one non-fatal -EAGAIN from `icc_pwrbutton_init: Failed to enable reset notifications`, expected).

**New blockers** that prevent rootfs lookup:

1. `xhci_aeolia 0000:00:14.7: Error while assigning device slot ID: Command Aborted` (14.5 s and 26.8 s) — xHCI host registers fine, but device enumeration fails. **No /dev/sdX appears, initramfs can't find `LABEL=psxitarch`.** This is the dominant blocker.
2. `ahci 0000:00:14.2: probe with driver ahci failed with error -12` (10.7 s) — `-ENOMEM` from the dedicated HDD AHCI controller. Likely coherent-DMA related.
3. `mmc0: Timeout waiting for hardware cmd interrupt` (18 s, 28 s) — SDHCI host up, eMMC device not answering CMD. Could be no eMMC on this CUH model.

Boot reaches `Run /init as init process` at 54.95 s; initramfs spins on `LABEL=psxitarch: Can't lookup blockdev` from 65 s onward.

Capture: `checkpoint/docs/uart-boot-2026-05-08-6x-bpcie-non-fatal.log` (2256 lines, line 15133 onward of the rolling capture).

**Next:** cherry-pick the 8 patches in `patches/rmuxnet-7.0-baikal/` (already extracted from rmuxnet's `ps4-baikal-7.0-port` branch). The "USB working motherfuckers" commit, the SATA-PHY/USB null-deref fix, the IRQ assignment patches, and the AMD IOMMU coherent-DMA patch are direct hits for our blockers 1-2. Stage as `0800-usb-aeolia/0003-…` and `1000-iommu/0002-…` after rebase.

---

## 2026-05-08 — 6.x boots to `/init`, real blocker identified

Worked from `research/build/` (clean-room copy of the 6.x-baikal target outside `linux-ps4/`). All 15 patches in `patches/6.x-baikal/series` apply cleanly to vanilla v6.15.4. Build via GCC 16.1.1 + Binutils 2.46.0, 4 min 46 s, zero errors, 1089 cosmetic warnings (mostly a single header-expansion artifact in amdgpu).

**Step 1 — install onto USB:** `scripts/swap-bzimage.sh` (mounts `/dev/sda1`, snapshots `bzImage` → `bzImage-prev`, bootstraps `bzImage-stable`, drops in new bzImage and a labeled copy `bzImage-6x-research-20260508-2111`).

**Step 2 — first boot (old bootargs):** Hung at 0.66 s as before. ~120 lines of UART, then silence.

**Step 3 — diagnose silence:** Discovered the UART log was getting `legacy bootconsole [uart8250] disabled`, after which `console=ttyS0,115200n8` directed printk to a phantom legacy 8250 at I/O `0x3F8`. The kernel was running silently, not hanging.

**Step 4 — bootargs update:** `scripts/dev/update-bootargs.sh` to set:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 keep_bootcon initcall_debug 8250.nr_uarts=0 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

(First attempt used `,keep` suffix on earlycon — kernel rejected it as a clkrate option. `keep_bootcon` as a separate parameter is the right way.)

**Step 5 — second boot, 1753 lines of UART:** Kernel reaches `Run /init` at 7.28 s. All 8 Baikal PCI functions detected with the expected vendor/device IDs (`0x104d:0x90d7..0x90de`), MSI domains created per-function via `bpcie_create_irq_domain`, amdgpu KMS enabled, ALSA HDA listed, sky2/xhci-aeolia/sdhci drivers init. Real blocker found at line 1284 of the boot log:

```
baikal_pcie 0000:00:14.4: Failed to register serial port 0
baikal_pcie 0000:00:14.4: bpcie glue remove
baikal_pcie 0000:00:14.4: probe with driver baikal_pcie failed with error -5
```

`bpcie_uart_init` calls `serial8250_register_8250_port` which fails in 6.x autoconfig (`port.type` unset → registration rejected). `bpcie_probe` aborts; every dependent driver (amdgpu, xhci-aeolia, ahci, sdhci, sky2) defers forever; initramfs spins on `LABEL=psxitarch: Can't lookup blockdev`.

**Wins:** PS4 patch foundation works on 6.x (`x86_ps4_early_setup`, EMC timer, MSI plumbing, IOMMU bypass via loader). Build pipeline reproduces clean. UART debugging unblocked.

**Next:** Patch `bpcie_probe` to make UART init failure non-fatal (5 LOC) — see PLAN.md priority #1.

**Side wins:**
- `keep_bootcon` is now confirmed safe on 6.x (was previously thought to crash). LEARNINGS.md updated.
- `checkpoint/docs/uart-boot-2026-05-08-6x-keep_bootcon-success.log` — extracted clean 1753-line boot log of the breakthrough.
- `checkpoint/docs/research/2026-05-08-6x-breakthrough.md` — detailed breakdown.
- `checkpoint/docs/research/gap-analysis-vs-our-tree.md` finding F1 (loader disables IOMMU on Baikal) confirmed empirically — `AMD-Vi: Using global IVHD EFR:0x0` in dmesg.
- `ps4-uart/ps4uart.py` patched to surface EACCES vs ENOENT vs EBUSY clearly (was logging only `# [!] Port lost` for any failure). Discovered while diagnosing why the capture wasn't running — user was missing the `uucp` group in the live shell session; `sg uucp -c '...'` is the workaround until next login.

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

---

## 2026-05-09 — Option B (bpcie MSI parent modernization)

After A→D dead ends in the previous session, started Option B: convert bpcie's
per-function MSI domain into a Linux 6.2-style MSI parent.

Built and hardware-tested 5 iterations:

- **v1** — parent flag + `msi_parent_ops` only. Boot OK but `init_dev_msi_info`
  never fired (the kernel never walked our domain).
- **v2** — added missing `dev_set_msi_domain(&bpcie_pdev->dev, domain)` install
  in `bpcie_create_irq_domains` loop. Kernel hung at 4.63 s — our wrapper
  recursed into itself because `real_parent->msi_parent_ops` is OUR ops.
  USB keyboard worked from this boot, suggesting xHCI MSI was already being
  routed correctly via legacy fallback before bpcie's own pdev hit recursion.
- **v3** — replaced wrapper with kernel helper `msi_parent_init_dev_msi_info`.
  No more recursion. Boot reached `/init` at 7.36 s. WARN at
  `x86_init_dev_msi_info+0xbd` because our domain has `bus_token=DOMAIN_BUS_ANY`
  but isn't `x86_vector_domain` itself (x86's gating switch only accepts
  ANY/DMAR/AMDVI). All child MSI allocs returned `-EPROBE_DEFER`.
- **v4** — `irq_domain_update_bus_token(domain, DOMAIN_BUS_AMDVI)` to satisfy
  x86's gate. WARN gone, but `baikal_pcie 0000:00:14.4: Failed to assign IRQs`
  — bpcie's own ICC alloc needed multi-MSI but our `supported_flags` ANDed it
  out from the per-device child info.
- **v5** — added `MSI_FLAG_MULTI_PCI_MSI` to `supported_flags`. Built (md5
  `69ae16d8…`). Pending hardware test (this commit).

Patch: `patches/6.x-baikal/0200-ps4-drivers/0007-ps4-bpcie-option-b-msi-parent.patch`.
Patch 0006 (Option A) disabled in series — mutually exclusive with 0007.

See `checkpoint/docs/LEARNINGS.md` "Linux 6.2 PCI MSI domain rework" for the full
diagnostic timeline including why each iteration failed.

## 2026-05-09 morning — Option B v6 (demuxer override) + amdgpu regression

Continued from yesterday's v5. Added custom `bpcie_init_dev_msi_info` wrapper
to override `info->handler = bpcie_handle_edge_irq` and `info->chip_data`
after the kernel helper, so bpcie's hardware demuxer would be in the leaf
chain.

Boot result: wrapper fires for each child pdev, parent-level msi_init runs,
real MSI vectors get programmed — but `bpcie_handle_edge_irq` STILL fires
zero times. xhci/sdhci/ahci/ICC all time out on completion interrupts.
**New regression**: amdgpu at slot 1 also timing out (gfx fence + sdma fence
+ illegal reg access errors), suggesting the `DOMAIN_BUS_AMDVI` bus_token
hack we put on bpcie is corrupting x86_vector's allocation state for
non-Baikal devices.

Architectural conclusion: 6.x's per-device MSI model splits each Baikal pdev
into its own domain → bpcie's subfunc demuxer can't resolve siblings via
`irq_find_mapping(domain, initial_hwirq + i)` because siblings live in
different domains. The 5.4 design used ONE shared bpcie domain.

Two paths for v7 (next session, after user input):
  1. Force legacy PCI MSI path (no parent flag, no parent_ops, kernel falls
     to pci_msi_legacy_setup_msi_irqs).
  2. Single shared bpcie domain across all 8 funcs (5.4 model).

See `checkpoint/docs/LEARNINGS.md` "Option B v6" for full diagnostic.

## 2026-05-09 afternoon — Option B v7 (BaikalLove insights) + boot-capture.sh

After surveying every branch in rmuxnet/ps4-linux-12xx and feeRnt/ps4-linux-12xx
(see `checkpoint/docs/research/2026-05-09-bpcie-msi-shape-index.md`),
applied 3 targeted changes from feeRnt's `x_exp__6.15.4-BaikalLove`:

1. msi_create_irq_domain → pci_msi_create_irq_domain
2. bpcie_msi_prepare: init_irq_alloc_info + arg->type = X86_IRQ_ALLOC_TYPE_PCI_MSI
   (was memset(arg, 0))
3. bpcie_msi_domain_info: add .handler_name = "edge"

Boot result (slice: `checkpoint/uart-logs/2026-05-09_1436-v7-baikallove.log`):

- amdgpu fence regression from v6 GONE (cleaner GPU init)
- bpcie_handle_edge_irq still 0 fires
- Same xhci/sdhci/ahci/ICC command timeouts

Full report: `checkpoint/docs/research/2026-05-09-v7-baikallove-result.md`.

Also added `scripts/dev/boot-capture.sh` — extracts named slices from the
rolling UART log with auto signal summary.  Documented in
`scripts/dev/README.md`.

## 2026-05-09 — v8 / Option D building (BaikalLove-faithful)

Architectural pivot away from Option B (per-device MSI parent).  Realized
PS4 Baikal southbridge does not pass child MSI writes to LAPIC — it
captures HT writes to `addr=0xFEE00000` and re-emits them as bpcie's own
MSI.  v1–v7 wrote real LAPIC vectors which the southbridge silently
dropped.

Changes in this build:
- Replaced `0007-ps4-bpcie-option-b-msi-parent.patch` with
  `0007-ps4-bpcie-option-d-baikallove.patch`.
- Added `int irq_map[100]` to `struct abpcie_dev`.
- New `bpcie_irq_msi_compose_msg` writing `addr_lo=0xFEE00000` + irq_map
  index.
- Removed `IRQ_DOMAIN_FLAG_MSI_PARENT`, `bpcie_msi_parent_ops`,
  `bpcie_init_dev_msi_info`, AMDVI bus_token override.
- Kept `pci_msi_create_irq_domain` and `dev_set_msi_domain` install.

Clean rebuild (header file changed, kbuild dependency tracking is fragile
on transitive #includes).  See
`checkpoint/docs/research/2026-05-09-option-d-thesis.md` for thesis.

Boot prediction: `bpcie_handle_edge_irq` should fire > 0 times.  If still
0, next suspect is the `apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask`
TODO (hardware enable register).

## 2026-05-09 — v9 / Option E built and tested

Architecture: v7 (routing scaffolding) + v8 (Baikal-magic composer +
irq_map[]).  Series file fixed (was referencing deleted option-b file
which silently skipped, making v8 a NULL test).  Patch
`0007-ps4-bpcie-option-e-routing-plus-baikal-composer.patch` (288 lines)
applied cleanly.  Clean build OK.

Hardware result: ALL software signals correct, `bpcie_handle_edge_irq`
still 0.  Spurious interrupt count = 0 (clean routing).  Failure is
hardware-level: missing HT-disable register write.  v10 is research +
implement `apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask`.

Full report: `checkpoint/docs/research/2026-05-09-v9-option-e-result.md`.

## 2026-05-09 — v10 / Option F built and tested

Implemented the day-1 TODO finally: faithful port of 5.4 Aeolia's
apcie_config_msi for Baikal.  Added 0008-ps4-bpcie-southbridge-msi-config.patch
on top of 0007 (v9 / Option E).  Build clean, all 23 patches applied.

Hardware result: bpcie_config_msi runs 41 times without crashing, but
a bug in func/subfunc extraction means we programmed function 0's MSI
slots with everyone's data (`func=0` in every log line, even xhci which
should be func=7).  bpcie_handle_edge_irq still fires 0 times.

Root cause: extracted `func = (data->hwirq >> 5) & 7` expecting Baikal's
`(slot << 8) | (func << 5) | subfunc` encoding.  That encoding only
exists at the bpcie parent domain level.  In 6.x's per-device MSI flow,
the LEAF data->hwirq is just the per-device subfunction index
(0..nvec-1).  All values < 32 decode to func=0.

v11 fix: extract func from PCI_FUNC(pdev->devfn), use data->hwirq
directly as subfunc.

What v10 DID prove (positive):
- BAR2 register block at 0x110000 is writable, no register-bus fault
- 41 sequential register writes completed without kernel crash
- Validates assumption #1 (BPCIE_RGN_PCIE_BASE = 0x110000)

Full report: checkpoint/docs/research/2026-05-09-v10-option-f-result.md

## 2026-05-09 — v11 / Option F (PCI_FUNC fix) tested

Fixed v10's func-extraction bug.  Verified samples now show func=4 for
bpcie's own MSIs, func=7 for xhci, func=3 for sdhci, func=2 for ahci.
But bpcie_handle_edge_irq still 0.

DEEPER architectural mistake spotted by reading 5.4 Aeolia: it uses
the kernel's standard irq_msi_compose_msg, NOT a custom composer.
Aeolia's apcie_config_msi gets called with REAL LAPIC encoding from
the standard composer.  We've been programming the southbridge's MSI
block with garbage (irq_map indexes) for 3 iterations because of v9's
unforced error of inventing a custom composer based on feeRnt's
BaikalLove (which is research, not a working baseline).

v12 = 1-line revert to x86_vector_msi_compose_msg + leave
bpcie_config_msi (the v10/v11 work) intact.  irq_map[] and
bpcie_irq_msi_compose_msg become dead code.

Full report: checkpoint/docs/research/2026-05-09-v11-result.md

## 2026-05-09 — v12 + intremap=off — 🎉 MILESTONE BOOT

After 12 iterations on bpcie MSI: everything working.  USB enumeration
(8 devices including a Gaming Keyboard with WORKING CAPS LOCK LED —
proving bidirectional HID I/O).  SATA disk fully attached and
partitioned (TOSHIBA MQ01ABD050 500 GB, 15 partitions sdb1..sdb31).
USB stick read.  amdgpu probed: VRAM/GTT/HDMI ready.  Bluetooth
RFCOMM/BNEP/HIDP socket layers loaded.  IPv6 + btrfs ready.

ZERO failures: 0 IOMMU events, 0 timeouts (Command Aborted, mmc0,
qc), 0 spurious interrupts, 0 kernel panics.

Final formula:
- v3-v7's MSI parent routing (IRQ_DOMAIN_FLAG_MSI_PARENT +
  msi_parent_ops + AMDVI bus_token)
- v12's revert to standard kernel x86_vector_msi_compose_msg
- v10/v11's bpcie_config_msi southbridge programming
- bootargs: iommu=pt intremap=off (passthrough DMA + disable
  interrupt remapping which was blocking Baikal's HT-MSI delivery)

Full report: checkpoint/docs/research/2026-05-09-v12-MILESTONE.md

## 2026-05-09 — v13: per-subfunc mask (no ICC fix, but boot reached /init)

Added per-subfunc Baikal mask handling to bpcie_msi_unmask/mask
(0010 patch, 91 lines).  Hypothesis: ICC's MSI was masked at the
subfunc bit level even though function-level enable was set in
bpcie_config_msi.

Result: ZERO regressions vs v12 (USB/SATA/amdgpu/ALSA all preserved),
boot now reaches /init at t=239s — but ICC timeouts unchanged (15).
The vector 0xE3 "No irq handler" message still fires at t=5.86s.

Concluding ICC needs a different fix — likely related to bpcie MEM
function 6 setup (icc_init relies on mem_dev BAR5 mapping for SPM
mailbox region).  Deferring ICC investigation.

Pivot to v14 = enable Baikal GbE in sky2 (PCI ID line commented out
with "is this broken maybe?" hint).  Goal: get SSH access for better
remote debugging.

Full report: checkpoint/docs/research/2026-05-09-v13-result.md

## 2026-05-09 — v14: sky2 Baikal GbE attempt failed; pivoting to GPU

Uncommented BAIKAL_GBE PCI ID (104d:90d8) in 0700-network-sky2 patch.
Sky2 module DID see the device this time (vs probe returning -ENODEV
in v13), but failed at chip-detection:

  sky2 0000:00:14.1: unsupported chip type 0x0
  sky2 0000:00:14.1: probe with driver sky2 failed with error -95

Plus warning: BAR 0 is only 4 KB but sky2 expects 16 KB.  Suggests
Baikal GbE registers are accessed via a different BAR or window than
standard Marvell Yukon expects.  Crashniels has same ❌ on Ethernet —
this is a deeper problem that needs reverse-engineering, not a
surface-level fix.

User explored USB-Eth dongle alternative — dongle didn't enumerate
on PS4 (likely USB power budget; needs keyboard unplugged).

Pivoted to amdgpu GPU acceleration.  Key findings from v14 log:
- "amdgpu can't find IRQ for PCI INT A" — amdgpu got NO IRQ
- 16+15+15 illegal instruction events, 13 GPU resets all failed
- Boot ran systemd userspace (NetworkManager-dispatcher,
  systemd-homed, alsa-restore, etc.) for ~7 minutes generating spam

GPU situation:
- ArabPixel payload extracts liverpool_pfp/me/ce/mec/mec2/rlc/sdma
  firmware to /lib/firmware/amdgpu/ at boot
- Our gfx_v7_0.c references those firmware files via MODULE_FIRMWARE
- BUT amdgpu probes at t=115s, real rootfs likely mounts later
- Plus amdgpu didn't even get an IRQ → all command-completion polls fail

v15 = port rmuxnet c0066db41 "amdgpu: require MSI/MSI-X for PS4
Liverpool IRQs" — eliminates INTx fallback for Liverpool/Gladius
ASICs, force MSI.  Expectation: amdgpu gets a real LAPIC vector,
IRQ delivery works, command completion notifications arrive, GPU
reset/recovery loops stop.  May unblock display init too if the
cascade was IRQ-driven.

Boot log: checkpoint/uart-logs/2026-05-09_1950-v14-baikal-gbe.log

## 2026-05-09 — v15: amdgpu force-MSI for Liverpool — partial GPU win

Hand-adapted port of rmuxnet c0066db41 to our 6.15.4 amdgpu_irq.c
(rmuxnet's patch had context drift since they're on a different
kernel version).  0005-amdgpu-require-msi-for-liverpool.patch (101
lines) under 0300-gpu-liverpool/ — adds amdgpu_irq_is_ps4_asic()
helper plus a CHIP_LIVERPOOL/CHIP_GLADIUS branch in amdgpu_irq_init
that forces PCI_IRQ_MSI|PCI_IRQ_MSIX (no INTx fallback).

Hardware result (boot 2026-05-09 20:24, 26 patches applied=0 fail):
- amdgpu now gets MSI (no more "can't find IRQ for PCI INT A" trip
  through INTx fallback that has no routing on PS4)
- Early-boot GPU reset loop ELIMINATED — first ~5 min of boot has
  zero "GPU reset" / "asic atom init failed" events
- v12 milestone preserved: bpcie_msi_init=68, USB enum=8, no
  Spurious 0xef, no Command Aborted/Timeout, no panics
- Boot reached SYSTEMD USERSPACE (confirmed by user via UART logs
  showing systemd-hostnamed etc.)

But GPU still hits illegal-instruction errors (7+11+28 total
across CP/RLC/SDMA) because Liverpool firmware (extracted by
ArabPixel payload to /lib/firmware/amdgpu/liverpool_*.bin) isn't
available at amdgpu probe time (~t=115s) — rootfs not mounted yet.
amdgpu starts CP without microcode → every command rejected.

Later (~t=366s, after systemd is up):
- amdgpu_job_timedout fires (job submission times out)
- drm_sched_job_timedout → amdgpu_device_gpu_recover
- gmc_v7_0_suspend (during reset prep)
- asic atom init failed
- GPU reset(2) failed

Recovery path fails because ATOM BIOS init needs ICC i2c (which is
the SAME ICC that's failing for ps4_bridge/display).  So the real
post-v15 bottleneck for GPU is ICC, not the IRQ allocation.

Next candidate paths:
- Investigate ICC (would unlock display + GPU recovery)
- Get firmware into initramfs so amdgpu probe finds CP microcode
- Both together → GPU acceleration likely works

Boot log: checkpoint/uart-logs/2026-05-09_2024-v15-amdgpu-force-msi.log

## 2026-05-09 — v16: Liverpool firmware in initramfs — ALL CP errors gone 🎉

Added 10 liverpool_*.bin firmware files (pfp/me/ce/mec/mec2/rlc/sdma/
sdma1/uvd/vce) to /lib/firmware/amdgpu/ inside USB's initramfs.cpio.gz
(NOT boomerang-initramfs.cpio.gz — first attempt updated wrong file;
discovered when boot showed kernel still loading 4 MB initramfs even
after our 15 MB boomerang got bigger).  No kernel/patch changes.

Hardware result (boot 2026-05-09 20:50):
- gfx_v7_0_priv_inst_irq:        0  (was 14 in v15)
- gfx_v7_0_priv_reg_irq:         0  (was 15 in v15)
- cik_sdma_process_illegal_inst: 0  (was 28 in v15)
- GPU reset:                     0  (was 0 — preserved)
- asic atom init failed:         0  (was 0)
- All v12 milestone signals preserved (USB enum=8, no Spurious,
  no Command Aborted, bpcie_msi_init=68)

Boot reaches /init at t=239s, then graceful shutdown at t=254s
(amdgpu shutdown, sd shutdown, sync cache).  Confirms PS4
shutdown/reboot path works (matches crashniels published status).

Caps lock LED still works (bidirectional USB HID).

Display still blocked by ICC i2c failures — ps4_bridge can't talk
to HDMI bridge chip → "Cannot find any crtc or sizes" → no
modeset → no display output.  ICC is the LAST remaining
significant blocker for HDMI.

Boot log: checkpoint/uart-logs/2026-05-09_2050-v16-firmware-correct-initramfs.log

## 2026-05-10 — v44: Liverpool preserve-BIOS-PLL diagnostic

Patches:
- 0300-gpu-liverpool/0018-amdgpu-atombios-i2c-rename-to-readedid.patch
  — cosmetic rename ProcessI2cChannelTransaction → ReadEDIDFromHWAssistedI2C,
    matching ps4gentoo's original 1fef36f5 reference (no-op functionally
    because they're #define aliases in our atombios.h).
- 0300-gpu-liverpool/0019-amdgpu-dce-v8-liverpool-preserve-bios-pll.patch
  — supersedes disabled v33; in dce_v8_0_crtc_mode_set for Liverpool,
    dump all four DCCG_PLL[0..3] register banks plus PIXCLK[0..2] resync
    regs, then skip every ATOM-driven mode_set call (set_pll, set_dtd_timing,
    overscan_setup, scaler_setup), only run do_set_base + cursor_reset.

bzImage: output/6.x-baikal/bzImage  md5 8999ea68d90d99d34cab9fbdfe415d10
Bootargs: 6.x-edid-v40-nocrs (v40 ACPI fix + intremap=off + pci=nocrs +
                              EDID firmware + 1920x1080@60D)
UART log: checkpoint/uart-logs/2026-05-10_1454-v44-liverpool-preserve-bios-pll.log

Result: ❌ HDMI dark.  Diagnostic dump shows all four PPLL banks at 0.
PIXCLK1_RESYNC_CNTL = 0x1 (proves MMIO works), other PIXCLK = 0.

Conclusion: PS4 firmware does NOT leave display PLL programmed across
the kexec into Linux.  The "preserve BIOS state" mental model is wrong.
Linux must program the display PLL itself.  v40 ACPI fix is independently
correct; ATOM AdjustDisplayPll continues to return 0 (PS4 VBIOS table
appears stub).

Next iteration: v45 — manual PLL programming for Liverpool 1080p60 with
hand-computed dividers, targeting PPLL1 (per PIXCLK1_RESYNC routing).

Full analysis: checkpoint/docs/research/2026-05-10-v44-liverpool-preserve-bios-pll-result.md

## 2026-05-10 — v45: Liverpool manual PLL programming (writes silently dropped)

Patches:
- 0300-gpu-liverpool/0020-amdgpu-dce-v8-liverpool-manual-pll-program.patch
  — supersedes v44's preserve-BIOS-PLL short-circuit. For Liverpool/Gladius
    in dce_v8_0_crtc_mode_set, hardcode 1080p60 PLL dividers (ref_div=1
    fb_int=11 fb_frac=14 post=8 → 148.44 MHz from 100 MHz refclk), pack
    per VGA*_PPLL_* bit layout, write to all four mmDCCG_PLL[0..3]
    register banks. Dump PRE+POST PLL state for verification.

bzImage: output/6.x-baikal/bzImage  md5 8b3c5680977fd82328364e2eb15f662f
Bootargs: 6.x-edid-v40-nocrs (unchanged from v44)
UART log: checkpoint/uart-logs/2026-05-10_1510-v45-liverpool-manual-pll-program.log

Result: ❌ HDMI dark. POST-program read shows IDENTICAL all-zero values
to PRE-program. Our WREG32 returns without error but the registers
don't store the writes.

Three new realizations from deeper log read + source cross-check:

  1. NO code in 5.4-baikal directly writes to mmDCCG_PLL[0..3]_* either.
     The visually-confirmed-working baseline produces HDMI without anyone
     touching these registers. Strongly implies they're NOT the actual
     display PLL on Liverpool.

  2. amdgpu has no PLL indirect-access path (RREG32_PLL/WREG32_PLL
     undefined). radeon has them but uses radeon_invalid_rreg for CIK.
     So the writes-dropping isn't an indirect-access issue.

  3. WREG32 to DCCG block IS valid (dce_v8_0.c:1537-1539 uses it
     successfully for AUDIO_DTO regs). Our writes reach hardware,
     but specifically these PLL register offsets either need a lock
     protocol, are gated, or aren't the real display PLL.

Other notable details from deeper log read:
  - VBIOS string "113-Starsha2-018" (Starsha2 = PS4 Slim Liverpool
    codename). VBIOS IS parsed by amdgpu, not stub.
  - GPU register MMIO base = 0xE4800000 (BAR 5, 256 KB)
  - 2nd bridge_enable takes 2.97s vs 1st 1.34s — cq_wait_set steps
    for DP lane status silently timing out (no DP signal).
  - call_irq_handler vector 2.61 storm with 977 callbacks suppressed
    correlates with 2nd bridge_enable. Bridge raising IRQs nobody
    handles.
  - Encoder = "DFP1: INTERNAL_UNIPHY"
  - HPD1 detected, DDC i2c works (0x194c..0x194f)

Conclusion: the v44/v45 mental model "kexec leaves PPLL at zero, just
program them" is now in question. Either we're targeting wrong
registers entirely (most likely given 5.4 evidence) or the protocol is
more complex than guessed. Need ATOM IIO trace to find the actual
registers ATOM SetPixelClock targets on Liverpool — that data is
upstream of any further "manual PLL programming" attempts.

Self-critique: should have done ATOM IIO trace first as recommended
by the multi-agent ideas synthesis. v44/v45 cost two boots and
half a day on a hypothesis that turned out testable in 5 minutes
of source grep ("does anyone in 5.4 write these registers?" — no).

Full analysis: checkpoint/docs/research/2026-05-10-v45-liverpool-manual-pll-program-result.md


# 2026-05-10 evening — v46→v60 — HDMI WORKING (THE FIX)

After 16 iterations chasing the dark-screen on PS4 6.x-baikal, v60
brought HDMI up. User photo (~/Downloads/IMG_20260510_195300931.jpg)
shows initramfs rendering text at boot.

The fix: **do not call setup_dig_transmitter(DISABLE) and
setup_dig_transmitter(ENABLE) on PS4 Liverpool/Gladius DP encoders
during modeset.** PS4 firmware leaves the GPU's UNIPHYA DP transmitter
already trained and locked to the MN864729 bridge with per-lane
voltage swing / pre-emphasis values that are not derivable from VBIOS
object info. Linux's standard DPMS_OFF/ON cycle reprograms those
PHY-state values to ATOM defaults (`ucDPLaneSet=0`), immediately
invalidating the receiver's adaptive equalization. Once broken, the
kernel has no working trainer to recover (PS4 bridge doesn't speak
DPCD; patch 0006 makes dp_link_train early-return).

Final patch stack (active for HDMI):
- 0022 v47 — floor `dp_clock=270000` in adjust_pll
- 0023 v49 — clobber `adev->clock.dp_extclk=0` so picker selects PPLL2
- 0026 v52 — floor `dig_connector->dp_clock=270000, dp_lane_count=4`
- 0031 v59 — skip `setup_dig_transmitter(DISABLE)` for Liverpool DP
- 0032 v60 — skip `setup_dig_transmitter(ENABLE)` for Liverpool DP

Disabled (proven wrong / superseded):
- 0019 v44 (preserve-bios-pll), 0020 v45 (manual-pll-program)
- 0027 v53 (TX SETUP/SETUP_VSEMPH), 0028 v54 (source-only DP train)

Diagnostic patches kept (verbose; consider removing for v61 cleanup):
- 0021 v46 (ATOM ret/in/out trace)
- 0024 v50 (generic ATOM table tracer)
- 0025 v51 (DIG/TX args + PIXCLK trace)
- 0029 v55 (bridge cq trace + chunk split)
- 0030 v58 (step-by-step bridge probe `ps4_bridge_probe_lane_status`)

The two crucial diagnostic patches were v55 (split monolithic
MN864729 main seq into 3 chunks at wait boundaries) and v58
(intra-modeset probe of `0x60f8/0x60f9`). v55 reframed the
problem from "bridge needs help" to "we broke the lock"; v58
localized the killer to a single ATOM action in one boot.

Visual proof at second-cycle bridge_enable in v60 log:
- chunk A elapsed: 520ms (was 605ms timeout in v59)
- readback 0x60f8: 0xff (was 0x0f in v59 — broken)
- readback 0x60f9: 0x1b (was 0x1a in v59)
- total bridge_enable second cycle: 1.66s (was 3.85s in v59)
- HDMI signal emerges; initramfs text visible on screen

Per-iteration result files: checkpoint/docs/research/2026-05-10-v46
through v60-*.md. The v60 result file documents the full bisection
narrative across 16 iterations.

## 2026-05-11 — v70 (UVD/VCE IP block adds) → exposed firmware-name gate

Triggered by community Q on uvd/vce: another contributor (bzz) is on
this in parallel. Hypothesis from the room: "we're pretty close" =
probably this same firmware-name plumbing.

v70: stripped /* ... */ wrappers around uvd_v4_2_ip_block and
vce_v2_0_ip_block adds in cik_set_ip_blocks (patch 0001 lines 788–789
and 806–807) for both CHIP_LIVERPOOL and CHIP_GLADIUS. Otherwise
untouched.

Result: IP blocks 6/7 register correctly, HDMI bridge programs
normally (chunks A/B/C all rc=20), but amdgpu_uvd_sw_init returns
-EINVAL at t=9.740s because amdgpu_uvd.c / amdgpu_vce.c have no
CHIP_LIVERPOOL/GLADIUS case in their firmware-name switch — falls
through to default: -EINVAL before liverpool_{uvd,vce}.bin is even
requested. amdgpu probe unwinds with 12 amdgpu_irq_put warnings, no
fbcon → blank HDMI. Internal WiFi + SSH stayed up.

v71 candidate: patches/6.x-baikal/0300-gpu-liverpool/0033-amdgpu-uvd-vce-liverpool-firmware-name.patch
adds the CHIP_LIVERPOOL/CHIP_GLADIUS cases + the corresponding
#define / MODULE_FIRMWARE macros. Built but not yet tested on
hardware. Expected outcomes outlined in
checkpoint/docs/research/2026-05-11-v70-uvd-vce-result.md.

Rollback path if v71 still breaks display: bzImage-prev on USB is
v68 (post-v67); bzImage-stable is v60 HDMI-working baseline.
