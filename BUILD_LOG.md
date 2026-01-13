# PS4 Linux Kernel Build Log

## Target Hardware
- **Console:** PS4 Slim
- **Southbridge:** Baikal B1 (0x30201)
- **WiFi/BT:** MediaTek MT7668

---

## Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| Base Kernel | 6.15.4 | crashniels ps4-linux-6.15.y-baikal |
| Patches Applied | 1 | bpcie-icc pointer fix (via sed) |
| Config | Ready | crashniels base + MT7668 + debug |
| Build | SUCCESS | bzImage 9.6MB |
| Boot Test #1 | FAILED | Black screen - old initramfs |
| Boot Test #2 | PENDING | Using new minimal initramfs |

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
