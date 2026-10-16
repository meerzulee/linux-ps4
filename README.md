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
| HDMI audio | Partial; stream accepted but no physical sound |
| Bluetooth | Controller present; pairing pending |
| Temperature and fan | Temperature visible; fan interface missing |
| Suspend | Not exposed by the kernel |
| Internal Linux installation | Not supported |

The detailed matrix is in [STATUS.md](STATUS.md). The acceptance sequence is
in [CAPABILITY-TESTS.md](docs/CAPABILITY-TESTS.md). Omarchy readiness is tracked
in [OMARCHY-READINESS.md](docs/OMARCHY-READINESS.md).

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

### Get the PS4 sources

For the current development stack, clone this patch/configuration repository:

```sh
git clone --branch agent/document-baikal-capabilities \
  https://github.com/meerzulee/linux-ps4.git linux-ps4-kernel
cd linux-ps4-kernel
```

The complete upstream Linux source is downloaded automatically by `build.sh`
when you build. `targets/6.18-baikal.env` records its repository
`https://github.com/gregkh/linux.git`, tag `v6.18.44` and required commit
`1efe5d048a391de3ead2804b2e7f86376c356cc5`. The builder checks that commit
before applying the PS4 patches. You do not need to copy `src/` from another
computer or substitute an unrelated PS4 kernel fork.

### macOS ARM64 (Apple Silicon)

Use OrbStack for the Linux build environment. Install the host tools and start
OrbStack before building:

```sh
brew install git bash python coreutils zstd xz
orb status
# Must report Running.
docker context show
# Must report orbstack.
docker info >/dev/null
./scripts/build-kernel-orbstack --target 6.18-baikal
```

The helper runs an ARM64 Linux container with `x86_64-linux-gnu-` cross
compilation and `KERNEL_ARCH=x86_64`. The output is a PS4 x86-64 kernel.
Do not run `make` or `build.sh` directly on Darwin.

### Linux x86-64 (Arch)

The native build does not need Docker or a virtual machine:

```sh
uname -m
# Must report x86_64.
sudo pacman -Syu --needed base-devel git bc cpio pahole libelf openssl \
  kmod perl python rsync xz zstd ripgrep
make TARGET=6.18-baikal
```

`build.sh` fetches the pinned upstream kernel and applies the committed series.
`make init` additionally downloads reference repositories and firmware; it is
not required for the normal build from the current checkout. A new Arch
compiler can produce different artifact bytes from the pinned OrbStack build:
check the manifest and matching modules before considering hardware use.

Both paths write build outputs to `output/6.18-baikal/`. Do not overwrite a
known-good release output when comparing candidates. These are host build
instructions; a build passing is not a new hardware acceptance result.

Older targets remain available for comparison and recovery:

```sh
make TARGET=5.4-baikal
make TARGET=6.x-baikal
```

Read [AGENTS.md](AGENTS.md) before development. In the full workspace, the
sibling `omarchy-ps4/docs/DEVELOPMENT-HOSTS.md` also covers distribution setup
and the current OrbStack-only image builders.

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
