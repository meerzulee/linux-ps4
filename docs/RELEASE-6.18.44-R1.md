# Linux 6.18.44 PS4 Baikal r1

This is the first public 6.18 LTS **pre-release** from the patch-based
`linux-ps4` build. It is intended for PS4 Baikal developers with a recovery
path and UART access.

## Hardware evidence

The released bzImage is the exact A39 artifact tested on a PS4 Slim with a
Baikal B1 southbridge and firmware 12.02. Experiments A43 and A51 reached
stable 1920×1080 at 60 Hz, LightDM and XFCE. A51 also connected through the
internal MT7668, obtained a DHCP lease, and accepted pinned-key SSH.

## Boot boundary

This release does **not** install Linux to the PS4 internal disk. The tested
chain uses:

1. GoldHEN PayLoader and ps4-linux-loader v25;
2. kernel, initramfs and boot arguments from the USB FAT partition;
3. Arch/XFCE root filesystem from the USB ext4 partition labeled
   `OMARCHY-PS4`.

No initramfs, root filesystem, proprietary PS4 firmware, per-console key, or
payload is bundled with the kernel release.

## Assets

| Asset | Purpose | SHA-256 |
|---|---|---|
| `bzImage` | hardware-tested kernel | `b54490ed1f5d12432bf4ead11f27f1cf8aed008f0b76787c0060141b97414614` |
| `config` | exact resolved kernel configuration | `922dc16e4928b69cf711f377a29c75c9627d534ad3a2a208dc3b3f1dd61cf234` |
| `SHA256SUMS` | asset integrity list | verify after download |

The tested root filesystem has no `/usr/lib/modules/6.18.44-ps4-baikal`
directory; the hardware paths used in A51 are built into the kernel. No module
archive is published for r1. Optional modules can be built from the tagged
source and exact config.

## Known limitations

- Internal Toshiba SATA reads time out during discovery and add roughly 96
  seconds to boot. Sony partitions must remain unmounted and untouched.
- Built-in Ethernet is not working.
- EGL/OpenGL acceleration, Vulkan, HDMI audio, Bluetooth, DualShock 4,
  thermals and repeated cold boots are not release-accepted yet.
- The kernel currently includes verbose development diagnostics.
- This is a pre-release, not a general-user distribution image.

## Source and credit

The release is based on Linux `v6.18.44` commit
`1efe5d048a391de3ead2804b2e7f86376c356cc5` and 54 active PS4 patches. Exact
crashniels, feeRnt, rmux and local source links are recorded in
[PATCH-PROVENANCE.md](PATCH-PROVENANCE.md). Borrowed patches preserve original
authors where available; locally adapted behavior is labeled as such.

- release `series` SHA-256:
  `614e4bf8ef13997dfb4b564e747ceac176cda6b9481948ee4118b518af374c82`
- ordered active patch-content SHA-256:
  `64f26872e363234b7e83f3b310225b1ae727f154490376b3ce7f969c69e22e56`

After the A39 hardware build, source URLs were expanded in comments and patch
headers. No kernel hunk or resolved config changed. The release tag therefore
uses the two source-metadata identities above and the same compiled kernel
code as the tested A39 bzImage.
