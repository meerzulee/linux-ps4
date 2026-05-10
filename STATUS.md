# Status — PS4 Linux on Baikal

Snapshot as of 2026-05-10 (commit `b02d1c6`, tag `v62-wifi-ssh`).
For chronological history see [BUILD_LOG.md](BUILD_LOG.md);
for current focus see [checkpoint/docs/PLAN.md](checkpoint/docs/PLAN.md).

## What works

| Subsystem | 5.4 | 6.x | Notes |
|---|---|---|---|
| **Boot to userspace** | ✅ | ✅ | systemd, multi-user.target |
| **HDMI display (1080p60)** | ✅ | ✅ | 6.x via v60 fix (preserve firmware DP TX) |
| **USB enumeration** | ✅ | ✅ | xhci_aeolia / xhci_baikal |
| **SATA storage** | ✅ | ✅ | AHCI on 0000:00:14.7 (xhci dual-purpose) |
| **Internal eMMC / SD** | ✅ | ✅ | sdhci-pci |
| **HID (keyboard / mouse)** | ✅ | ✅ | Generic USB HID |
| **Audio (analog + HDMI)** | ✅ | ⚠️ | 6.x: snd_hda detected, not fully tested |
| **WiFi (USB TP-Link RTL8822BU)** | ⚠️ | ✅ | Driver: rtw88_8822bu. 6.x added in v62 |
| **WiFi (built-in MT7668)** | ✅ | ❌ | mt76x8 vendor driver only in 5.4. 6.x port: WIP |
| **Bluetooth (built-in MT7668)** | ✅ | ❌ | Same as above |
| **SSH from host** | ✅ | ✅ | Via WiFi adapter |
| **Switch_root into psxitarch** | ✅ | ✅ | better-initramfs + bootargs/6.x-rootfs-psxitarch.txt |

## What doesn't work yet

| Subsystem | Status | Notes |
|---|---|---|
| **Ethernet (built-in Marvell)** | ❌ | sky2 driver doesn't recognize the Baikal MAC. Class code is `0x088001` (System peripheral, not Ethernet). 38 non-zero registers in BAR0 at offsets that don't match Yukon-2. **Multi-week RE project**, no upstream reference. See [`checkpoint/docs/research/2026-05-10-sky2-baikal-not-yukon.md`](checkpoint/docs/research/2026-05-10-sky2-baikal-not-yukon.md). Parked. |
| **MT7668 in 6.x** | 🚧 WIP | Vendor tree imported as `patches/6.x-baikal/0500-network-mt7668/0001-mt76x8-vendor-tree-import.patch`. Build infrastructure parses but produces no .o files (vendor's MTK_COMBO_CHIP indirection, 2.6-era kbuild assumptions). Needs ~2-3 days of Makefile rework + 5.4→6.x API porting. |
| **GPU 3D acceleration** | ❓ | amdgpu KMS works (HDMI). Mesa userspace + 3D rendering not yet tested on 6.x. |
| **Suspend / resume** | ❌ | ICC dependency unverified on 6.x. |
| **Fan / thermal management** | ❓ | hwmon (fam15h_power, k10temp) loads. Fan speed control via APcie ICC not yet tested. |
| **GPU reset / recovery** | ❌ | GPU jobs that timeout cause cascade failures (uses ATOM BIOS init via ICC). |
| **HDD permanent install** | ❓ | Internal HDD enumerates as `sdb` but has Sony's encrypted partitions. Need a partitioning strategy that doesn't break PS4 OS recovery. |

## Hardware identification

| PCI ID | Function | Status |
|---|---|---|
| `104d:9920..9924` | PS4 console PCI device IDs (model-specific) | ✅ identified |
| `104d:90d0..90df` | 8 BPCIe (Baikal southbridge) functions | ✅ all 8 detected |
| `104d:90d8` | Baikal Ethernet Controller | ❌ not Yukon-2, custom MAC |
| `1002:9923` | AMD Liverpool GPU | ✅ amdgpu working |
| `1002:9924` | AMD HD audio (HDMI) | ✅ snd_hda |
| `2357:0138` | TP-Link Archer T3U Plus (RTL8822BU) | ✅ rtw88_8822bu |

## Build status

| Target | Builds | Boots | Configs |
|---|---|---|---|
| `5.4-baikal` (`v5.4.247`) | ✅ Clang 22 | ✅ | feeRnt-derived working config |
| `6.x-baikal` (`v6.15.4`) | ✅ GCC 14+ | ✅ | + RTW88, + MT76X8 (build skipped, WIP) |

## Outstanding tracks

Active investigation tracks (most likely next steps):

1. **MT7668 6.x port** — replace USB WiFi adapter with internal radio. ~2-3 days. See [`checkpoint/docs/study/08-mt7668-port-todo.md`](checkpoint/docs/study/08-mt7668-port-todo.md).
2. **GPU 3D acceleration** — Mesa stack on 6.x. May Just Work given KMS works.
3. **CI/CD** — GitHub Actions for build + Releases (Phase 2 of repo modernization).
4. **Multi-version target framework** — easier porting to upcoming 7.x kernels.
5. **Upstreaming** — first candidate is the v60 DP TX preservation patch. See [CONTRIBUTING.md](CONTRIBUTING.md#upstreaming).

Parked indefinitely:

- **sky2 Baikal** — multi-week RE, no upstream reference. WiFi adapter satisfies the connectivity need.

## How to test current state

```sh
# Build
make TARGET=6.x-baikal

# Stage to PS4 USB stick (FAT32 partition labeled PS4BOOT, ext4 labeled psxitarch)
sudo bash scripts/swap-bzimage.sh output/6.x-baikal/bzImage
sudo bash scripts/dev/update-bootargs.sh 6.x-rootfs-psxitarch

# Move USB to PS4, run PSFree+ArabPixel gauntlet, kexec linux-1024mb.bin
# Watch UART live: cd ps4-uart && python3 ps4uart.py live
```

After boot reaches `archlinux login:`:

```sh
# On the PS4 console:
sudo modprobe rtw88_8822bu                       # if you have the TP-Link adapter
sudo nmcli device wifi connect "<SSID>" password "<pass>"
ip -br addr show

# Then SSH from host:
ssh ps4@<IP-from-nmcli>
```
