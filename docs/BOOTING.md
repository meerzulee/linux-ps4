# Booting the kernel with general Linux or Omarchy

This repository builds a **Linux kernel for PS4 Baikal**, not a distribution
image. It can be paired with different Linux distributions. Omarchy is an
optional distribution and launcher, and the owner's USB layout is one example.
The public candidate is experimental: only the original private build has the
recorded Baikal B1 hardware results. Other PS4 models and PS5 are not qualified.

## Components you need

| Component | Role | Supplied by this kernel release? |
| --- | --- | --- |
| Compatible PS4 Linux loader/payload | Loads the kernel, initramfs and command line on the console | No; use your established compatible loader |
| `bzImage` | PS4 Linux kernel | Yes |
| Matching complete module tree | Drivers for that exact kernel build | Yes |
| Compatible PS4 initramfs | Early USB/root discovery, required firmware and switch to the real root | No; use or build one compatible with your loader and layout |
| Linux x86-64 root filesystem | Your distribution, init system and applications | No; Arch, Debian, Fedora or another suitable distribution is a separate choice |
| Device firmware | Vendor firmware requested by Wi-Fi/display drivers | No; provide applicable firmware and notices separately |
| Boot arguments | Describe your root device and boot options | Two examples; choose and adapt one |

The Omarchy PS4 launcher is one way to launch a compatible loader. Another
compatible PS4 Linux loading method can use the same kernel. A standard PC
installer/GRUB USB alone does not supply the PS4-specific loading chain.
This repository does not install a launcher, jailbreak, root filesystem or
internal-disk bootloader.

## General Linux: choose your own root filesystem

1. Keep your established PS4 loader and recovery boot set. Identify the console
   southbridge and verify your existing Linux USB works before testing this
   candidate. Keep UART and a local recovery console; Wi-Fi availability with
   this firmware-free build is not yet qualified.
2. Prepare a compatible **Linux x86-64** root filesystem and initramfs. The
   initramfs must support the actual USB/root filesystem, resolve your chosen
   root identifier and switch to your distribution's init. Include device
   firmware needed before the root is mounted, particularly for built-in Wi-Fi.
3. Install the complete module archive side by side under the new kernel
   release directory and run `depmod` for that release. Preserve old modules.
   The archive uses `lib/modules/`; account for your distribution's `/lib` and
   `/usr/lib` layout. See [the tester guide](TESTING-MTS2-PUBLIC.md).
4. Start with `bootargs-generic.example.txt` from the release, versioned as
   [the generic USB example](../bootargs/6.18-baikal-generic-usb.example.txt).
   **Edit it for your system**, then save the chosen line as the loader's
   `bootargs.txt`. The example assumes an ext4 root labelled `PS4LINUX` and an
   initramfs that resolves `root=LABEL=...`. Replace the label or use your
   initramfs's supported UUID/PARTUUID/device syntax; do not format or relabel
   an existing filesystem merely to match the example.
5. The generic example keeps internal SATA disabled and enables console/UART
   diagnostics for the tested Baikal address. It has no Omarchy splash, root
   layout or service arguments. Display/EDID and console settings may need
   your already-working values. If using `drm.edid_firmware=...`, provide the
   referenced EDID in the compatible initramfs; the release supplies none.
6. Follow your established loader's external-file layout. With the tested
   v25 USB override, put all four selected files together at the FAT root:
   `bzImage`, compatible `initramfs.cpio.gz`, chosen `bootargs.txt`, and
   `vram.txt` (`1024` for the tested 1024 MB loader). Do not substitute a VRAM
   setting for a different loader variant. Other loaders may use different
   names or layouts; follow their documentation.
7. Use one bounded UART experiment for installation/fresh boot/observation.
   Verify `uname -r`, matching modules and the expected root filesystem before
   testing devices. Restore the entire backed-up boot set if boot fails.

The generic command line is an **untested template**, not a claim that every
root filesystem or distribution has been tested. Module dependencies and
userspace tools remain distribution responsibilities.

## Omarchy: optional tested layout example

For the existing partitioned Omarchy PS4 system, the release supplies
`bootargs-omarchy.txt`, versioned as
[the exact EXP016 command line](../bootargs/6.18-baikal-mts2-omarchy-usb.txt).
It assumes the owner's compatible Omarchy initramfs, a FAT boot partition,
ext4 root labelled `OMARCHY-PS4`, 1080p EDID firmware and the 1024 MB loader.
It includes `omarchy.*` arguments interpreted by that initramfs. These are
Omarchy-specific settings and are not required by the kernel or Ethernet driver.

Choose this example only with that compatible layout; copy it to `bootargs.txt`
for the loader. The public rebuild has a different release/config/compiler
identity and no embedded firmware, so the original boot result does not qualify
it automatically. Its own hardware acceptance remains pending. The existing
Omarchy launcher PKG need not be updated merely to select an external kernel.
Distribution integration and automatic startup remain in the separate project:

https://github.com/meerzulee/omarchy-ps4

## Ethernet and distribution networking

The kernel's `psx_mts_net` driver has no dependency on Omarchy, systemd or
NetworkManager. It provides a Linux netdevice named `psx0`, but this
experimental version requires an explicit first-open gate, strict fresh-state
checks and one retained DMA generation per boot. A command line alone does
not activate it. Never unload/reset/rearm a published instance.

An **optional NetworkManager adapter** is included for distributions using NM,
Python 3, iproute2 and kmod. It implements the reviewed gate/open/verify/handoff
sequence and creates only its named DHCPv4 profile. It does not install or
enable a startup service. Follow [manual activation](TESTING-MTS2-PUBLIC.md).

Other networking stacks, such as systemd-networkd or dhcpcd, may use the Linux
netdevice, but an equivalent reviewed activation adapter and hardware test
are still needed. Do not run multiple managers on `psx0`, and do not replace
the guarded activation sequence with an unverified gate write.

## Development host is a separate choice

The kernel output targets PS4 x86-64 regardless of host: use the OrbStack
cross-build helper on macOS ARM64 or native tools on Linux x86-64. GitHub CI
uses a native Linux x86-64 runner. The root filesystem distribution on the
PS4 need not match the build host. See [the build instructions](../README.md).
