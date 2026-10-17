# linux-ps4

Patch-based Linux kernel builds for PlayStation 4, currently targeting
**Linux 6.18.44 on PS4 Baikal**. Upstream Linux, configuration and patch order
are pinned so the build inputs and their origins can be inspected.

[Download Baikal r1](https://github.com/meerzulee/linux-ps4/releases/tag/v6.18.44-ps4-baikal-r1)
· [Hardware status](STATUS.md)
· [Patch provenance](docs/PATCH-PROVENANCE.md)
· [Contributing](CONTRIBUTING.md)

## Tested hardware

The published build was tested on one **PS4 Slim with a Baikal B1 southbridge**:

- system firmware `12.02`;
- ps4-linux-loader v25 with `linux-1024mb.elf`;
- external USB boot and Arch Linux root filesystem;
- Xorg and XFCE at 1920×1080/60 Hz;
- internal MediaTek MT7668 Wi-Fi and SSH over Wi-Fi.

Other PS4 revisions, including PS4 Pro, are not yet verified by this project.
The kernel is one part of the boot stack; a compatible loader, initramfs and
root filesystem are required separately.

## Published r1 kernel status

These states describe the published Baikal kernel and its recorded hardware
results. A smoke test does not establish sustained or repeatable operation.

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
| HDMI audio | Partial; stream accepted but no physical sound |
| Bluetooth | Controller present; pairing pending |
| Temperature and fan | Temperature visible; fan interface missing |
| Suspend | Not exposed by the kernel |
| Internal Linux installation | Not supported |

See [STATUS.md](STATUS.md) for the detailed matrix,
[CAPABILITY-TESTS.md](docs/CAPABILITY-TESTS.md) for acceptance criteria and
[OMARCHY-READINESS.md](docs/OMARCHY-READINESS.md) for distribution readiness.

## Experimental Ethernet kernel

The optional **`6.18-baikal-mts2`** target builds
`6.18.44-ps4-baikal-mts2` with the native polled Baikal MTS Ethernet module.
On the same Baikal B1 console, EXP-20261017-016 passed modem DHCP, preferred
wired IPv4 routing, independent hash-checked 4 MiB transfers in both directions,
verified HTTPS, three NetworkManager profile reconnects and operation beyond
900 seconds. Wi-Fi recovery remained available.

This is an experimental candidate. EXP016 is DEGRADED overall: its first
automatic startup exposed a userspace handoff gap; a corrected manual sequence
worked, while unattended package0.1.1 startup, cable recovery and strict
packet-gating acceptance remain pending. Other PS4 revisions are untested.
The stable/default target and its support matrix above are unchanged.

Read the [kernel, module and boot contract](docs/BAIKAL-MTS-KERNEL-CANDIDATE.md),
[bring-up findings](docs/BAIKAL-ETHERNET-BRINGUP.md) and
[tested boot settings](docs/RELEASE-6.18.44-MTS2.md). The driver is built as
`psx_mts_net.ko` and requires explicit gated activation after `baikal_pcie`.
It has no PCI-alias autoload; boot arguments alone do not enable Ethernet.
The Omarchy activation package is maintained separately and is not included
in this kernel repository. Automatic setup from a kernel-only clone is not
yet provided. Published DMA and module code remain retained until power-off;
do not unload, reset or rearm a published instance.

## Download

[Linux 6.18.44 PS4 Baikal r1](https://github.com/meerzulee/linux-ps4/releases/tag/v6.18.44-ps4-baikal-r1)
is a developer build for the tested hardware. Its downloadable assets are:

| Asset | Purpose |
|---|---|
| `bzImage` | Exact kernel tested on the PS4 Slim |
| `config` | Resolved configuration used for that kernel |
| `SHA256SUMS` | Checksums for both assets |

The r1 release does not include a module archive. Building from source produces
matching modules and the additional records listed below. Read the
[release notes](docs/RELEASE-6.18.44-R1.md) for the tested boot chain and limits.

The kernel download does not include a loader payload, initramfs, root
filesystem, Sony system firmware or per-console keys. The kernel configuration
embeds MediaTek device firmware; those bytes have separate licensing from the
Linux code. See [the firmware inventory](firmware/README.md). The tested system
boots from external USB; this is not an internal-disk installer.

## Build from source

### Get this repository

```sh
git clone https://github.com/meerzulee/linux-ps4.git linux-ps4-kernel
cd linux-ps4-kernel
```

This repository contains the PS4 patches, configs and build tools. The complete
upstream Linux tree is downloaded automatically by `build.sh`. For the default
target, [targets/6.18-baikal.env](targets/6.18-baikal.env) pins:

| Input | Value |
|---|---|
| Upstream repository | `https://github.com/gregkh/linux.git` |
| Upstream tag | `v6.18.44` |
| Required commit | `1efe5d048a391de3ead2804b2e7f86376c356cc5` |
| PS4 patch order | `patches/6.18-baikal/series` |
| Configuration | `config/6.18-baikal.config` plus target fragments |

The builder verifies the upstream commit before applying patches. No private
source archive or copy of another computer's generated `src/` is required.
`make init` downloads extra reference repositories and firmware; it is optional
for the normal kernel build from this checkout.

### macOS ARM64 — Apple Silicon

Install Git and OrbStack, including its `orb` and Docker command-line tools.
Start OrbStack, then check the runtime before building:

```sh
orb status
# Must report Running.
docker context show
# Must report orbstack.
docker info >/dev/null
./scripts/build-kernel-orbstack --target 6.18-baikal
```

The helper uses the pinned builder image definition and an ARM64 Linux
container with the `x86_64-linux-gnu-` cross-compiler. Its output targets the
PS4's x86-64 CPU. Run the helper on macOS rather than invoking the Linux
`build.sh` directly on Darwin. OrbStack is the supported local container runtime.

### Linux x86-64 — Arch Linux

Build natively; no Docker container or virtual machine is required:

```sh
uname -m
# Must report x86_64.
sudo pacman -Syu --needed base-devel git bc cpio pahole libelf openssl \
  kmod perl python rsync xz zstd ripgrep
make TARGET=6.18-baikal
```

The same target definition, patch series and config are used on both hosts.
A different compiler can produce different artifact bytes; compare the build
manifest and use modules from the same build as the kernel.

### Select the experimental Ethernet target

```sh
# macOS ARM64, after the OrbStack checks above:
./scripts/build-kernel-orbstack --target 6.18-baikal-mts2
# Linux x86-64:
make TARGET=6.18-baikal-mts2
```

Use `output/6.18-baikal-mts2/` and its whole matching module archive.
The predecessor `6.18-baikal-mts` builds the bounded, single-open mts1
experiment and is retained for investigation. Do not use it for continuous
networking. Both optional targets preserve the tested `NETFILTER=n` baseline;
the regular target now includes a separate UFW fragment. Do not infer firewall
support for mts2 from the regular target.

### Build outputs

Both paths write to `output/6.18-baikal/`:

| Output | Purpose |
|---|---|
| `bzImage` | Bootable kernel image |
| `config` | Resolved kernel configuration |
| `System.map` | Kernel symbol map |
| `modules-<kernel-release>.tar.zst` | Matching runtime module tree |
| `manifest.txt` | Upstream, patch, config, compiler and builder identities |
| `version.txt` | Kernel release string |
| `SHA256SUMS` | Output checksums |

From that output directory, verify with `sha256sum -c SHA256SUMS` on Linux or
`shasum -a 256 -c SHA256SUMS` on macOS. Preserve known-good outputs before
rebuilding the same target. A successful compilation is a build result;
hardware acceptance is recorded separately.

Older targets remain available for comparison and recovery:

```sh
make TARGET=5.4-baikal
make TARGET=6.x-baikal
```

`6.x-baikal` is the archived 6.15 development target.

## Repository layout

```text
targets/                 pinned kernel versions and build settings
patches/6.18-baikal/      baseline PS4 patch series
patches/6.18-baikal-mts2/ optional continuous Ethernet series
config/                  kernel configs and fragments
bootargs/                tested kernel command lines
containers/kernel-builder/ pinned Linux build environment
scripts/dev/             UART, USB and test-loop helpers
checkpoint/              bring-up research and historical records
experiments/baikal-mts/  historical GPL experiment sources
docs/                    release, hardware and provenance notes
```

Generated `src/` trees are disposable build state. Save intended kernel changes
as ordered patches before rebuilding. Follow [CONTRIBUTING.md](CONTRIBUTING.md)
for the patch workflow and [AGENTS.md](AGENTS.md) for development rules.

## Hardware development

Use a bounded UART experiment for a coherent hardware question. Record the
kernel identity, boot arguments, expected result and recovery path, then close
the capture and record the observed outcome. Change one diagnostic variable
at a time; compilation and a single boot do not establish release stability.

Do not mount, repair, format or write to the PS4 internal disk during bring-up.
See [INTERNAL-STORAGE.md](docs/INTERNAL-STORAGE.md).

For the Arch/Omarchy distribution and its installation workflow, see
[Omarchy PS4](https://github.com/meerzulee/omarchy-ps4).

## Documentation

| Document | Contents |
|---|---|
| [STATUS.md](STATUS.md) | Hardware results and remaining limits |
| [Baikal Ethernet bring-up](docs/BAIKAL-ETHERNET-BRINGUP.md) | Investigation, implementation and measured limits |
| [MTS2 kernel and boot settings](docs/RELEASE-6.18.44-MTS2.md) | Exact built candidate, checksums and boot contract |
| [6.18-PORT.md](docs/6.18-PORT.md) | Linux 6.18 port and acceptance history |
| [HARDWARE.md](docs/HARDWARE.md) | Platform and hardware notes |
| [PATCH-PROVENANCE.md](docs/PATCH-PROVENANCE.md) | Original contributors and immutable source links |
| [ORIGINAL_CONTRIBUTIONS.md](ORIGINAL_CONTRIBUTIONS.md) | Local work and upstream basis |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributor workflow |

## Credits and license

- whitehax0r — original Baikal port;
- DFAUS / feeRnt — Linux 5.4.247 work and MT7668 driver;
- crashniels — Linux 6.15 Baikal forward-port;
- rmuxnet — southbridge, storage, IRQ, xHCI, IOMMU and display work;
- fail0verflow and the wider PS4 Linux community — platform research and tools.

Borrowed and adapted patches retain their authors and source provenance.
The kernel patches are GPL-2.0 unless a file states otherwise; see
[LICENSE](LICENSE) and individual file headers. Firmware files and any embedded
firmware keep their own licensing; they are not relicensed by this repository.
