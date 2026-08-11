# Status — PS4 Linux on Baikal

Snapshot: 2026-08-11. The default target is Linux `6.18.44` with local version
`-ps4-baikal`. Claims below distinguish the exact hardware-tested target from
older 6.15 experiments.

## Tested platform

- PS4 Slim, Baikal B1 southbridge, firmware 12.02
- ps4-linux-loader v25, `linux-1024mb.elf`
- external Kingston USB: FAT boot partition plus ext4 root labeled
  `OMARCHY-PS4`
- Arch Linux, Xorg, XFCE 4.20
- internal MediaTek MT7668 Wi-Fi

## Linux 6.18.44 result

| Capability | State | Evidence / limitation |
|---|---|---|
| Kernel and initramfs | Working | `6.18.44-ps4-baikal` build `#5` reached initramfs repeatedly |
| CPU | Working smoke test | All eight Jaguar cores are online and accepted pinned work; no cpufreq policy is exposed; sustained load is blocked on fan visibility |
| Memory | Working candidate | 6.8 GiB is usable; bounded allocation testing is still pending |
| External USB root | Working | Kingston ext4 root resolved as `/dev/sda2` and mounted read-write |
| HDMI 1080p60 | Working candidate | A43 and A51 displayed XFCE; true cold-boot repetition is still required for release-stability status |
| XFCE/Xorg | Working | LightDM reached graphical target and started user session `ps4` |
| Internal MT7668 Wi-Fi | Working | NetworkManager associated and obtained a DHCP lease in A51 |
| OpenSSH | Working candidate | Pinned-key login as `ps4` passed; repeat after a true cold boot |
| USB RTL8822BU fallback | Driver present | Requires uncompressed `rtw88/rtw8822b_fw.bin` in userspace |
| Internal SATA | Degraded | Toshiba disk probes, but IDENTIFY/read timeouts delayed root discovery by about 96 seconds; Sony partitions were not mounted or modified |
| Built-in Ethernet | Not working | Prior `sky2` work did not produce a usable transmit path |
| GPU acceleration | Working smoke test | amdgpu/radeonsi direct rendering, OpenGL 4.6 and an eight-second 59.17 FPS `glxgears` test passed without a new GPU warning; sustained rendering remains pending |
| Vulkan | Working smoke test | RADV exposed Vulkan 1.3 and rendered `vkcube` for eight seconds without a new GPU warning |
| HDMI audio | Partial | HDA, ALSA and PipeWire enumerate; direct HDMI stereo PCM accepted a bounded test stream; human confirmation is pending |
| USB | Working | Aeolia xHCI runs the external root disk, keyboard and mouse |
| Bluetooth / DualShock 4 | Partial | MT7668 `hci0` and firmware are present; BlueZ is installed but its service is disabled; pairing is pending |
| Temperature | Partial | `k10temp` reports plausible values around 60–61°C |
| Fan control | Not exposed | No fan RPM or PWM interface is visible; do not run sustained stress tests |
| Suspend/resume | Not supported | `/sys/power/state` and `/sys/power/mem_sleep` are absent |
| Internal Linux installation | Not supported | The tested system boots kernel and root filesystem from external USB |

## Exact accepted kernel artifact

- bzImage SHA-256:
  `b54490ed1f5d12432bf4ead11f27f1cf8aed008f0b76787c0060141b97414614`
- base: Linux `v6.18.44` commit
  `1efe5d048a391de3ead2804b2e7f86376c356cc5`
- active patches: 54
- hardware-positive experiment artifact: A39

See [docs/6.18-PORT.md](docs/6.18-PORT.md) for the port history and acceptance
gate, and [docs/PATCH-PROVENANCE.md](docs/PATCH-PROVENANCE.md) for immutable
source URLs.

## Build

Linux 6.18 is now the default:

```sh
# Linux host
make

# macOS: OrbStack must be running and Docker context must be orbstack
./scripts/build-kernel-orbstack
```

Use `make TARGET=5.4-baikal` for the recovery baseline or
`make TARGET=6.x-baikal` for the archived 6.15 development target.

## Next acceptance work

1. Diagnose internal SATA timeouts without mounting or modifying Sony data.
2. Repeat the unchanged artifact from a true cold boot.
3. Add fan visibility/control before sustained CPU or GPU load.
4. Confirm HDMI audio, start BlueZ, and test DualShock 4 pairing.
5. Diagnose the recurring `No irq handler for 0.227` warning.
6. Fix guest time synchronization and test clean shutdown.
7. Only then begin minimal Wayland, bare Hyprland and Omarchy layers one at a
   time.
