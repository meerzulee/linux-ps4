# linux-ps4

Patch-based Linux kernel builds for PlayStation 4. The default target is
Linux `6.18.44` with the PS4 Baikal patch set.

## Tested hardware

This release is tested on one **PS4 Slim with a Baikal B1 southbridge**:

- system firmware `12.02`;
- ps4-linux-loader v25 with `linux-1024mb.elf`;
- external USB boot and Arch Linux root filesystem;
- Xorg and XFCE at 1920×1080/60 Hz;
- internal MediaTek MT7668 Wi-Fi;
- SSH over Wi-Fi.

Other PS4 revisions, including PS4 Pro, are not yet verified by this project.

## Current status

| Capability | State |
|---|---|
| Linux 6.18.44 boot | Working |
| External USB root | Working |
| HDMI, Xorg and XFCE | Working |
| Internal MT7668 Wi-Fi | Working |
| SSH | Working |
| GPU acceleration | OpenGL and Vulkan smoke tests working |
| Internal SATA | Degraded; discovery timeouts |
| Built-in Ethernet | Not working |
| HDMI audio | Partial; human confirmation pending |
| Bluetooth | Controller present; pairing pending |
| Temperature and fan | Temperature visible; fan interface missing |
| Suspend | Not exposed by the kernel |
| Internal Linux installation | Not supported |

The detailed matrix is in [STATUS.md](STATUS.md). The acceptance sequence is
in [CAPABILITY-TESTS.md](docs/CAPABILITY-TESTS.md).

## Release

[Linux 6.18.44 PS4 Baikal r1](https://github.com/meerzulee/linux-ps4/releases/tag/v6.18.44-ps4-baikal-r1)
is a developer pre-release. It contains:

- `bzImage` — the exact kernel tested on the PS4 Slim;
- `config` — the resolved kernel configuration;
- `SHA256SUMS` — checksums for the release assets.

The release does not contain a payload, initramfs, root filesystem, Sony
firmware, per-console keys or proprietary device firmware. It boots Linux from
external USB and does not install to the internal disk.

## Build

```sh
make init
make
```

On macOS, use OrbStack:

```sh
./scripts/build-kernel-orbstack
```

OrbStack must be running and the active Docker context must be `orbstack`.
Build outputs are written to `output/6.18-baikal/`.

Older targets remain available for comparison and recovery:

```sh
make TARGET=5.4-baikal
make TARGET=6.x-baikal
```

## How the repository works

The kernel source is not forked here. `build.sh` fetches a pinned upstream
Linux tag, applies the ordered patches in `patches/<target>/series`, installs
the target config and records the resulting artifacts and checksums.

```text
targets/                 pinned kernel versions and build settings
patches/6.18-baikal/     active PS4 patch series
config/                  resolved kernel configs and fragments
bootargs/                tested kernel command lines
scripts/dev/             UART, USB and test-loop helpers
checkpoint/              bounded logs and bring-up research
docs/                    release, hardware and provenance notes
```

Every borrowed or adapted patch should retain its author and immutable source
URL. See [PATCH-PROVENANCE.md](docs/PATCH-PROVENANCE.md) for the source ledger
and [ORIGINAL_CONTRIBUTIONS.md](ORIGINAL_CONTRIBUTIONS.md) for the local work.

## Development rule

Change one variable per boot. Start a bounded UART capture, perform the test,
stop the capture, and record the kernel artifact, boot arguments and result.
Do not use an endless UART tail as evidence.

Do not mount, repair, format or write to the PS4 internal disk during bring-up.
See [INTERNAL-STORAGE.md](docs/INTERNAL-STORAGE.md).

## Credits

- whitehax0r — original Baikal port;
- DFAUS / feeRnt — Linux 5.4.247 work and MT7668 driver;
- crashniels — Linux 6.15 Baikal forward-port;
- rmuxnet — current southbridge, storage, IRQ, xHCI, IOMMU and display work;
- fail0verflow and the wider PS4 Linux community — platform research and tools.

The kernel patches are GPL-2.0 unless a file states otherwise. Runtime firmware
blobs are not bundled and remain under their respective vendor licenses.
