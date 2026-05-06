# PS4 Linux — Baikal kernel build system

A patch-based build system for porting Linux to PlayStation 4 consoles
with the **Baikal** southbridge (PS4 Slim CUH-2xxx, PS4 Pro CUH-7xxx,
Baikal-B1 ID 0x30201, MediaTek MT7668 WiFi/BT).

Two kernel targets are wired up out of the box:

| Target | Base | Status | Compiler |
|---|---|---|---|
| `5.4-baikal` | vanilla v5.4.247 + 13 patches | Builds (boot pending) | Clang 22 + LLD |
| `6.x-baikal` | vanilla v6.15.4 + 15 patches | Builds (boot pending) | GCC 15 |

The 5.4 target is a faithful re-creation of feeRnt's `5.4.247-baikal-dfaus`
branch. The 6.x target is the forward-port: crashniels'
`ps4-linux-6.15.y-baikal` split into per-subsystem patches, plus a couple
of small fixes layered on top.

## Quick start

```sh
# First-time setup: clone reference repos (~10GB) and download firmware
make init

# Build the 5.4 baseline (Clang)
make TARGET=5.4-baikal

# Build the 6.x port (GCC)
make TARGET=6.x-baikal

# Outputs land in output/<target>/{bzImage,config,System.map,version.txt}
```

To install modules into a stagable directory:

```sh
cd src/<target>
make INSTALL_MOD_PATH=../../output/<target>/modules modules_install
```

## Repo layout

```
linux-ps4/
├── build.sh                    # ./build.sh -t <target>
├── Makefile                    # `make TARGET=<target>` shortcuts
├── targets/
│   ├── 5.4-baikal.env          # base repo, ref, config, compiler
│   └── 6.x-baikal.env
├── patches/
│   ├── 5.4-baikal/             # 13 patches mirroring feeRnt's stack
│   │   ├── series              # apply order
│   │   ├── 0100-x86-platform/
│   │   ├── 0200-ps4-drivers/
│   │   ├── 0300-gpu-liverpool/
│   │   ├── 0400-storage-ahci/
│   │   ├── 0500-storage-sdio/
│   │   ├── 0600-wifi-mt7668/   # ~214k-line MT7668 vendor driver
│   │   ├── 0700-network-sky2/
│   │   ├── 0800-usb-aeolia/
│   │   ├── 0900-hwmon/
│   │   ├── 1000-iommu/
│   │   ├── 1100-pci-msi/
│   │   └── 1200-misc/
│   └── 6.x-baikal/             # 15 patches forward-ported from 5.4
│       ├── series
│       ├── 0100-x86-platform/
│       ├── 0200-ps4-drivers/
│       ├── 0300-gpu-liverpool/ # adds radeon Liverpool, amdkfd, drm_bridge
│       ├── 0400-storage-ahci/
│       ├── 0500-storage-sdio/
│       ├── 0700-network-sky2/
│       ├── 0800-usb-aeolia/
│       ├── 0900-hwmon/
│       ├── 1000-iommu/         # path moved to drivers/iommu/amd/ in 6.x
│       ├── 1100-pci-msi/       # heavily refactored vs 5.4
│       └── 9000-todo/          # mt7668 forward-port, etc.
├── config/
│   ├── 5.4-baikal.config       # full .config — feeRnt's 5.4 working config
│   ├── 6.x-baikal.config       # full .config — feeRnt's 6.15 working config
│   └── fragments/              # mergeable additions (UART, debug, etc.)
├── firmware/                   # firmware blobs embedded into the kernel
├── scripts/
│   ├── clone-refs.sh           # clone reference upstreams to tmp/
│   ├── download-firmware.sh
│   ├── generate-5.4-patches.sh # regenerator for patches/5.4-baikal/
│   ├── generate-6.x-patches.sh # regenerator for patches/6.x-baikal/
│   └── ...
├── tmp/                        # reference repos (gitignored, ~10GB)
└── src/, output/               # gitignored build dirs (per-target)
```

## How patches are sourced

### 5.4-baikal

Diff between vanilla v5.4.247 and feeRnt's
`ps4-linux-12xx 5.4.247-baikal-dfaus` (HEAD `1fdfbd9a4`), bucketed by
subsystem. Plus one local patch (`-mhard-float` removal so the kernel
builds with Clang 16+; feeRnt's CI pinned Clang 14).

100% file coverage of the feeRnt tree — building from these patches
produces a kernel byte-equivalent to feeRnt's published 5.4 build.

### 6.x-baikal

Diff between vanilla v6.15.4 and crashniels'
`ps4-linux-6.15.y-baikal` (HEAD `b3b6b1e4f`), bucketed by subsystem.
crashniels has already absorbed the 5.4 work and forward-ported it,
including additional 6.x-only changes that 5.4 didn't have:

- **radeon Liverpool support** (legacy radeon driver, in addition to
  amdgpu)
- **amdkfd quirks** (compute / kernel fusion driver)
- **MSI subsystem rewrite handling** (`arch/x86/kernel/apic/msi.c`
  was replaced by `drivers/pci/msi/irqdomain.c` +
  `kernel/irq/irqdomain.c` + `arch/x86/kernel/apic/io_apic.c` +
  `vector.c`; `include/linux/msi.h` got a new layout)
- **iommu directory move** (`drivers/iommu/amd_iommu_init.c` →
  `drivers/iommu/amd/init.c`, plus a new `iommu.c`)
- **drm_bridge API tightening**

Plus 2 layered fixes:

- `0200-ps4-drivers/0002-ps4-bpcie-icc-fix-...patch` — `u32 addr` →
  `void __iomem *addr`. Same bug exists in 5.4 and 6.x trees; both
  series carry the fix as a real patch (not the previous sed hack
  in build.sh).
- `0800-usb-aeolia/0002-xhci-aeolia-baikal-shutdown.patch` —
  feeRnt's `b0969f7d101f`: original logic was "if not Belize, take
  the generic shutdown path", which misclassifies Baikal. Inverted
  to "only Aeolia takes the generic path".

## UART boot

The Baikal southbridge exposes 4 memory-mapped 8250-compatible UARTs
(BAR2 of the BPCIe device, `uartclk=58.5 MHz`, `regshift=2`,
MMIO32). Once `drivers/ps4/ps4-bpcie-uart.c` probes during boot,
they appear as standard `ttyS0…ttyS3`. Useful bootargs:

```
console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 loglevel=7
```

Earlyprintk via the Baikal UART won't fire pre-driver (the port is
not enumerated until BPCIe probes), so very-early-boot output isn't
available there. EFI earlyprintk is the workaround if needed.

## Outstanding work

- **MT7668 WiFi/BT in 6.x.** Not present in any 6.x reference tree
  (crashniels-6.15-baikal, feeRnt-6.15.4-baikal-crashniels,
  feeRnt-6.15.4-BaikalLove). 5.4 carries the full vendor driver
  (~214k lines, 250 files); forward-porting it is non-trivial. See
  `patches/6.x-baikal/9000-todo/README.md`.
- **Boot tests.** Both kernels build cleanly; neither has been
  booted on hardware as of the last log entry.

## Reference repos (cloned to `tmp/`)

| Repo | Branch | Role |
|---|---|---|
| crashniels-6.15 | `ps4-linux-6.15.y-baikal` | 6.x patch source |
| feeRnt-5.4.247-baikal | `5.4.247-baikal-dfaus` | 5.4 patch source |
| feeRnt-6.15.4-baikal-crashniels | `x_exp__6.15.4-baikal-crashniels` | xhci shutdown fix; reference 6.15 config |
| feeRnt-6.15.4-BaikalLove | `x_exp__6.15.4-BaikalLove` | alternate 6.15 reference |
| whitehax0r-5.4-baikal | `main` | original 5.4 squashed Baikal port |
| ps4boot-5.3-baikal | `baikal` | older 5.3 reference |
| vanilla-5.4.247 | tag `v5.4.247` | clean 5.4 baseline for diffing |
| vanilla-6.15.4 | tag `v6.15.4` | clean 6.15 baseline for diffing |

## Credits

- **whitehax0r** — original PS4 Baikal 5.4 port
- **DFAUS / feeRnt** — 5.4.247 refinement, MT7668 driver, build infra
- **crashniels** — 6.15 forward-port (the heavy lifting for 6.x)
- **fail0verflow** — original PS4 Linux work and tooling

## License

Patches are GPL-2.0, following the Linux kernel.
