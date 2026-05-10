# Status — PS4 Linux on Baikal

Snapshot as of 2026-05-11 (v67 commit `368a708`, v68 patch `<latest>`).
For chronological history see [BUILD_LOG.md](BUILD_LOG.md);
for current focus see [checkpoint/docs/PLAN.md](checkpoint/docs/PLAN.md).

## Headline numbers

| | Time | Boot fully reaches |
|---|---|---|
| **v62 baseline** | 8 min 28 s | login eventually |
| **v64 (Arch tweaks)** | 2 min 12 s | login |
| **v67 (full kernel + bootargs)** | **36 s** | login |

**14× boot speedup** through v62 → v67 via masked services, zram in-kernel, libata-disable for the broken Sony HDD, and tighter systemd timeouts.

## What works on 6.x (v67)

| Subsystem | 5.4 | 6.x | Notes |
|---|---|---|---|
| **Boot to userspace** | ✅ | ✅ | systemd, multi-user.target |
| **HDMI display (1080p60)** | ✅ | ✅ | 6.x via v60 fix (preserve firmware DP TX) |
| **USB enumeration** | ✅ | ✅ | xhci_aeolia / xhci_baikal |
| **SATA storage** | ✅ | ✅ | AHCI on 0000:00:14.7 |
| **Internal eMMC / SD** | ✅ | ✅ | sdhci-pci |
| **HID (keyboard / mouse)** | ✅ | ✅ | Generic USB HID |
| **Audio (analog + HDMI)** | ✅ | ⚠️ | 6.x: snd_hda detected, not fully tested |
| **WiFi (built-in MT7668)** | ✅ | ✅ | **v67: 754-line cfg80211 6.15+ port** — wlan0 binds, scans, connects |
| **Bluetooth (built-in MT7668)** | ✅ | ✅ | btmtksdio mainline, autoload via udev |
| **WiFi (USB TP-Link RTL8822BU)** | ⚠️ | ✅ | rtw88_8822bu still works as backup |
| **SSH from host** | ✅ | ✅ | Either WiFi adapter or internal MT7668 |
| **Switch_root into psxitarch** | ✅ | ✅ | better-initramfs + bootargs |
| **zram swap (1.5 GB zstd)** | — | ✅ | **v67**: in-kernel, active out-of-box |
| **Hyprland desktop** | — | ✅ | Wayland on Liverpool radeonsi 25.1 |

## What still doesn't work

| Subsystem | Status | Notes |
|---|---|---|
| **Ethernet (built-in Marvell sky2)** | 🔄 v68 in build | sky2 chip_id detection works (Yukon-2 OptimaEEE forced from raw 0x00). v67 hit `No interrupt generated using MSI` in the APCIE/BPCIE branch (test 0005 covered the wrong branch). v68 patch 0006 extends skip-test logic to the APCIE branch — pending boot test. |
| **GPU 3D acceleration** | ⚠️ Mesa works userspace | radeonsi 25.1.0-devel + RADV LIVERPOOL detected, OpenGL ES 3.2; KMS works. Hyprland renders. Full GL/Vulkan throughput not benchmarked. |
| **Suspend / resume** | ❌ | ICC dependency unverified on 6.x; not a priority. |
| **Fan / thermal management** | ❓ | hwmon (fam15h_power, k10temp) loads. Fan speed control via APcie ICC not tested; may need rmuxnet's Aeolia-fan-driver port. |
| **GPU reset / recovery** | ❌ | GPU jobs that timeout cause cascade failures (uses ATOM BIOS init via ICC). |
| **HDD permanent install** | ❓ | Internal HDD enumerates as `sdb` (or `sda` post-kexec — devices reorder). Has Sony's encrypted partitions. v67 disables ata1 by default to save boot time; would re-enable if you want to repartition for native install. |
| **HDMI after kexec** | ❌ | amdgpu doesn't recover after kexec (ICC link to bridge times out). Use full PSFree gauntlet for HDMI tests; kexec is fine for kernel/network/userspace work. |

## Hardware identification

| PCI ID | Function | Status |
|---|---|---|
| `104d:9920..9924` | PS4 console PCI device IDs (model-specific) | ✅ identified |
| `104d:90d0..90df` | 8 BPCIe (Baikal southbridge) functions | ✅ all 8 detected |
| `104d:90d8` | Baikal Ethernet Controller (Marvell Yukon-2 family) | 🔄 chip detection works, MSI delivery v68 |
| `1002:9923` | AMD Liverpool GPU | ✅ amdgpu working |
| `1002:9924` | AMD HD audio (HDMI) | ✅ snd_hda |
| `2357:0138` | TP-Link Archer T3U Plus (RTL8822BU) | ✅ rtw88_8822bu (USB backup) |
| `0e8d:7668` | MediaTek MT7668 (internal WiFi+BT, SDIO) | ✅ **v67 vendor port working** |

## Build status

| Target | Builds | Boots | Configs |
|---|---|---|---|
| `5.4-baikal` (`v5.4.247`) | ✅ Clang 22 | ✅ | feeRnt-derived working config |
| `6.x-baikal` (`v6.15.4`) | ✅ GCC 16 | ✅ | + RTW88, **+ MT76X8 builtin (v67)**, **+ ZRAM (v67)**, **+ libata force-disable HDD** |

## Outstanding tracks

Active investigation:

1. **v68 sky2 ethernet (in-flight)** — patch 0006 extends MSI-test skip to the APCIE/BPCIE early-bind branch. Awaiting USB swap + boot test. If eth0 binds → ethernet ships.
2. **GPU 3D benchmarks** — try `glmark2`, Vulkan demos. Most likely Just Works given Hyprland renders cleanly.
3. **Audio test on 6.x** — speaker-test, alsa, pipewire chain.
4. **CI/CD** — GitHub Actions for build + Releases (Phase 2 of repo modernization).
5. **Multi-version target framework** — easier porting to 7.x once mainline ships.
6. **Upstreaming candidates** — v60 DP TX preserve, v40 IRQ 9 desc, sky2 chip_id override (once full path proves), MT76X8 cfg80211 port (would need significant upstreaming work since vendor blob isn't mainline-friendly).

Parked indefinitely:
- **HDMI-after-kexec recovery** — needs ICC bridge reset sequence, multi-day RE.
- **Fan/thermal native control** — could port rmuxnet's Aeolia LED+fan driver but not a priority.

## How to test current state

```sh
# Build
make TARGET=6.x-baikal

# Stage to PS4 USB stick (FAT32 PS4BOOT, ext4 psxitarch)
sudo bash scripts/swap-bzimage.sh output/6.x-baikal/bzImage
sudo bash scripts/dev/update-bootargs.sh 6.x-rootfs-psxitarch
bash scripts/dev/boot-capture.sh start mybuildname

# Move USB to PS4, run PSFree+ArabPixel gauntlet, kexec linux-1024mb.bin
# Watch UART live: cd ps4-uart && python3 ps4uart.py live
```

After boot reaches `archlinux login:`:

```sh
# WiFi auto-connects via NetworkManager. Check:
ip -br addr
nmcli connection show --active

# Then SSH from host:
ssh ps4
```

Internal MT7668 wlan0 will be the primary interface; USB rtw88 still works as a backup if you have it plugged.

For kernel-only iteration (skip the PSFree gauntlet):
```sh
bash scripts/dev/kexec-from-ssh.sh
# follow on-screen instructions on PS4
# session dies, ssh back in ~30s
```
Note: kexec works for kernel/network/userspace tests. For HDMI tests, do a full power-cycle gauntlet (kexec doesn't restore HDMI on PS4 — bridge ICC stays dead).
