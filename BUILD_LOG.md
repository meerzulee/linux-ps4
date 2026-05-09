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
