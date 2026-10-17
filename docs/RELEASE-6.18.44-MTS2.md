# Linux 6.18.44 PS4 Baikal MTS2 — experimental build

Kernel: `6.18.44-ps4-baikal-mts2` (Linux x86-64, PS4 Slim Baikal B1).
This is the exact EXP-20261017-016 kernel, not a PS5 or general PS4 build.

Source and build inputs:
https://github.com/meerzulee/linux-ps4

The built kernel is provided to the owner locally. A public binary release
requires completion of the embedded device-firmware notice audit. Source,
patches, configuration and build tooling are published here.

## Built files

- `bzImage`: tested kernel.
- `modules-6.18.44-ps4-baikal-mts2.tar.zst`: the entire matching module tree.
- `bootargs.txt` and `vram.txt`: exact tested partitioned Omarchy USB settings.
- `config`, `System.map`, `manifest.txt`, `version.txt`: build records.
- `BUILD-SHA256SUMS`: original kernel build checksums.
- `SHA256SUMS`: checksums for this exported set.

## Existing Omarchy partitioned USB

The tested boot chain used ps4-linux-loader v25, its 1024 MB loader, a FAT
boot partition and an ext4 root partition labelled `OMARCHY-PS4`. The tested
initramfs SHA256 is
`31e793671aca8b595e130fa9d1ba5a93f0d777ee45843eb1aa3925294b0dc353`.
The initramfs and root filesystem are not included. These arguments depend
on that compatible initramfs and layout; they are not a universal installer.

Back up all existing boot files and preserve the previous module tree first.
On the mounted Linux root filesystem, extract the matching archive at its
root: it contains `lib/modules/6.18.44-ps4-baikal-mts2/`, with 54 files. On
Arch, `/lib` links to `/usr/lib`. Run depmod for the new release on Linux.
Put `bzImage`, the compatible `initramfs.cpio.gz`, `bootargs.txt` and
`vram.txt` together at the FAT root; the loader prefers USB files independently.
Do not combine kernel and modules from different builds. This folder does not
update the Omarchy launcher PKG or internal boot files.

The Ethernet driver is `psx_mts_net.ko`, built as an explicitly gated module.
Boot arguments alone do not activate it. The current Omarchy integration
uses the separately maintained `omarchy-ps4-ethernet` package 0.1.1. Its
corrected startup sequence worked manually; unattended startup is pending.
Do not load historical experiment modules over a retained driver or unload,
reset or rearm published MTS state. See the source candidate guide before
activation.

## Evidence and limits

On one Baikal B1 console, the integrated kernel passed modem DHCP, preferred
wired IPv4 routing, independent hash-checked 4 MiB transfers in each direction,
verified HTTPS, three NetworkManager profile reconnects and operation beyond
900 seconds. EXP016 is DEGRADED overall: cable recovery, strict packet-gating
acceptance, repeated cold boots and automatic package0.1.1 startup are pending.
This release is experimental; it does not promote stable Ethernet support.

Verify before use:

```sh
# Linux
sha256sum -c SHA256SUMS
# macOS
shasum -a 256 -c SHA256SUMS
```

The boot command line is supplied verbatim in `bootargs.txt`. It intentionally
keeps internal SATA disabled and uses the existing Omarchy USB initramfs.

## Exact tested command line

The loader reads one line from `bootargs.txt`:

```text
root=LABEL=OMARCHY-PS4 rootfstype=ext4 rootwait rw earlycon=uart8250,mmio32,0xC890E000,115200n8 console=null keep_bootcon 8250.nr_uarts=0 panic=0 quiet splash loglevel=7 ignore_loglevel printk.devkmsg=on drm.edid_firmware=edid/1920x1080.bin video=HDMI-A-1:1920x1080@60D vt.global_cursor_default=0 systemd.log_target=kmsg systemd.log_level=info systemd.show_status=false pci=nocrs intremap=off libata.force=1.00:disable omarchy.splash=1 omarchy.require_usb=1 omarchy.root_layout=partitioned-usb
```

The same line is versioned in
[`bootargs/6.18-baikal-mts2-omarchy-usb.txt`](../bootargs/6.18-baikal-mts2-omarchy-usb.txt).
`vram.txt` contains `1024` followed by a newline.

## Built artifact identities

| File | SHA256 |
| --- | --- |
| `bzImage` | `2c965bb52ed71c4086f2988486d0145a4d8399bbcc54cd78989e0cafc001e42d` |
| `config` | `7b04322c7fba8d89fe6280b613bfef80d4da2d82f6bf300d0388cd5479a6d963` |
| `modules-6.18.44-ps4-baikal-mts2.tar.zst` | `252399dc04e29de642096d64aef22aa8f2c33de3365494e5ada530dcf3e6ec24` |
| `manifest.txt` | `3596042f3d73caab851c6ae89ba2cef29651d21540f405989c5dd5da7ffd9054` |
| `bootargs.txt` | `dabd2779ac7f172ac3f534a93883694155d8b0c51d6fe2247597cc7fb111bb84` |
| `vram.txt` | `4f71bb761ace37c88826cd8cc1c948e1cf5b5d0cd153dc651a6efdb3dfb9f2b1` |

The built candidate includes MediaTek firmware via `CONFIG_EXTRA_FIRMWARE`.
Kernel GPL licensing does not replace device-firmware licensing. The Ethernet
implementation contains no Sony system firmware or proprietary driver code.
See [the firmware inventory](../firmware/README.md).
