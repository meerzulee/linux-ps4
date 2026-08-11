# Status — PS4 Linux on Baikal

Snapshot: 2026-08-11. The default target is Linux `6.18.44` with local version
`-ps4-baikal`. Claims below distinguish the exact hardware-tested target from
older 6.15 experiments.

## Tested platform

- PS4 Baikal B1, firmware 12.02
- ps4-linux-loader v25, `linux-1024mb.elf`
- external Kingston USB: FAT boot partition plus ext4 root labeled
  `OMARCHY-PS4`
- Arch Linux, Xorg, XFCE 4.20
- internal MediaTek MT7668 Wi-Fi

## Linux 6.18.44 result

| Capability | State | Evidence / limitation |
|---|---|---|
| Kernel and initramfs | Working | `6.18.44-ps4-baikal` build `#5` reached initramfs repeatedly |
| External USB root | Working | Kingston ext4 root resolved as `/dev/sda2` and mounted read-write |
| HDMI 1080p60 | Working candidate | A43 and A51 displayed XFCE; true cold-boot repetition is still required for release-stability status |
| XFCE/Xorg | Working | LightDM reached graphical target and started user session `ps4` |
| Internal MT7668 Wi-Fi | Working | NetworkManager associated and obtained a DHCP lease in A51 |
| OpenSSH | Working candidate | Pinned-key login as `ps4` passed; repeat after a true cold boot |
| USB RTL8822BU fallback | Driver present | Requires uncompressed `rtw88/rtw8822b_fw.bin` in userspace |
| Internal SATA | Degraded | Toshiba disk probes, but IDENTIFY/read timeouts delayed root discovery by about 96 seconds; Sony partitions were not mounted or modified |
| Built-in Ethernet | Not working | Prior `sky2` work did not produce a usable transmit path |
| GPU acceleration | Not accepted yet | KMS/fbcon works; EGL/OpenGL, sustained rendering and Vulkan remain separate 6.18 tests |
| HDMI audio | Not tested | HDA enumerates, but playback is not accepted |
| Bluetooth / DualShock 4 | Not tested | Requires bounded USB and Bluetooth tests |
| Thermal/fan control | Not accepted | Must be measured before long stress tests |
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
3. Verify EGL/OpenGL renderer and sustained GPU load.
4. Test HDMI audio, Bluetooth, DualShock 4, thermals and clean shutdown.
5. Only then begin minimal Wayland, bare Hyprland and Omarchy layers one at a
   time.
