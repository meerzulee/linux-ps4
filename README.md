# PS4 Linux — Baikal kernel build system

A patch-based build system for porting **mainline Linux** to PlayStation 4
consoles with the **Baikal** southbridge (PS4 Slim CUH-2xxx, PS4 Pro
CUH-7xxx; Marvell MT7668 WiFi+BT, AMD Liverpool/Gladius GPU).

> 🎉 **HDMI display works on 6.x as of v60 (`abe29da`, 2026-05-10).**
> WiFi via USB adapter (rtw88) + SSH from host works on 6.x as of v62 (`b02d1c6`).
> See [STATUS.md](STATUS.md) for the at-a-glance "what works" matrix.

> **What's original to this project vs forward-ported from upstream?**
> See [ORIGINAL_CONTRIBUTIONS.md](ORIGINAL_CONTRIBUTIONS.md) for the
> per-patch breakdown, evidence trail (UART logs + research files), and
> upstream candidates.

## Targets

| Target | Base | Status | Compiler |
|---|---|---|---|
| `5.4-baikal` | vanilla `v5.4.247` + 13 patches | ✅ Boots, KDE, WiFi (mt7668), SSH | Clang 22 |
| `6.x-baikal` | vanilla `v6.15.4` + 30 patches | ✅ **Boots to systemd**, HDMI, USB, SATA, WiFi (USB rtw88), SSH | GCC 14+ |

The `5.4-baikal` target is a faithful re-creation of feeRnt's
`5.4.247-baikal-dfaus`. The `6.x-baikal` target started as crashniels'
`ps4-linux-6.15.y-baikal` forward-port and now carries the major
display-bring-up work that took the project from "boots, no screen"
to "boots to a desktop with SSH".

## Quick start

```sh
# First-time setup: clone reference repos (~10 GB) and download firmware
make init

# Build the 6.x kernel (the active development target)
make TARGET=6.x-baikal

# Build the 5.4 baseline
make TARGET=5.4-baikal

# Outputs land in output/<target>/{bzImage,config,version.txt}
```

Then to install modules into a stagable directory:

```sh
cd src/<target>
make INSTALL_MOD_PATH=../../output/<target>/modules modules_install
```

For the full PS4 dev loop (UART capture, USB swap, bootargs profiles),
see [scripts/dev/](scripts/dev/) and [bootargs/README.md](bootargs/README.md).

## Repo layout

```
linux-ps4/
├── README.md                  # this file
├── STATUS.md                  # at-a-glance: what works, what doesn't
├── CONTRIBUTING.md            # how to contribute (bug reports, patches, upstreaming)
├── BUILD_LOG.md               # chronological development history
├── build.sh                   # ./build.sh -t <target>
├── Makefile                   # `make TARGET=<target>` shortcuts
├── targets/
│   ├── 5.4-baikal.env         # base repo, BASE_REF, config, compiler
│   └── 6.x-baikal.env
├── patches/
│   ├── 5.4-baikal/            # 13 patches mirroring feeRnt's stack
│   │   ├── series             # apply order
│   │   └── 0100..1200/        # bucketed by subsystem
│   └── 6.x-baikal/            # 30+ patches; v60 + v62 milestones
│       ├── series
│       ├── 0100-x86-platform/
│       ├── 0150-acpi/         # IRQ 9 desc fix (root cause for ATOM mutex)
│       ├── 0200-ps4-drivers/  # bpcie/icc/uart/MSI infrastructure
│       ├── 0300-gpu-liverpool/# amdgpu + bridge + DP TX fixes (v40-v60)
│       ├── 0400-storage-ahci/
│       ├── 0500-storage-sdio/
│       ├── 0500-network-mt7668/ # WIP — vendor tree imported, build infra needs rework
│       ├── 0700-network-sky2/
│       ├── 0800-usb-aeolia/
│       ├── 0900-hwmon/
│       ├── 1000-iommu/
│       └── 1100-pci-msi/
├── config/
│   ├── 5.4-baikal.config      # working 5.4 config
│   └── 6.x-baikal.config      # working 6.15 config
├── bootargs/                  # canonical kernel cmdline strings per scenario
├── checkpoint/
│   ├── docs/
│   │   ├── PLAN.md            # roadmap / current focus
│   │   ├── LEARNINGS.md       # diagnosis history (long form)
│   │   └── research/          # per-iteration result reports
│   └── uart-logs/             # captured UART excerpts per boot
└── scripts/
    └── dev/                   # helper scripts for the dev loop
        ├── swap-bzimage.sh
        ├── update-bootargs.sh
        ├── boot-capture.sh
        └── sky2-probe.py      # userspace BAR poker (RE tool)
```

## Notable milestones

| Tag | Commit | What |
|---|---|---|
| `v60-hdmi-working` | `abe29da` | **HDMI works on 6.x** — preserve firmware-trained DP TX state on Liverpool. Two patches skip `setup_dig_transmitter(DISABLE/ENABLE)` for Liverpool DP encoders. PS4 firmware leaves the GPU's UNIPHYA DP transmitter trained with per-lane swing/preemph values not derivable from VBIOS; standard DPMS_OFF/ON tears down the trained PHY and there's no working DPCD-based retrainer for the fake-DP MN864729 bridge. |
| `v62-wifi-ssh` | `b02d1c6` | **WiFi + SSH work on 6.x** via USB TP-Link Archer T3U Plus (rtw88_8822bu) since the built-in Marvell GbE turned out to not be a Yukon-2 (see `checkpoint/docs/research/2026-05-10-sky2-baikal-not-yukon.md`). |

For the full history of the v40 → v60 display-bringup saga, see
`checkpoint/docs/research/2026-05-10-v60-skip-tx-enable-result.md` —
it documents the 16-iteration bisection that found the fix.

## Adding new kernel versions

Each kernel target is one `targets/<name>.env` file plus one
`patches/<name>/` directory. To port to a new upstream release:

1. Copy `targets/6.x-baikal.env` to `targets/<NEW>.env`
2. Bump `BASE_REF` to the new tag (e.g., `v6.16.4`, `v7.0.1`)
3. Copy `patches/6.x-baikal/` to `patches/<NEW>/`
4. Run `./build.sh -t <NEW>` and fix any patch-rejects

That's it — the build system is target-agnostic. See
[CONTRIBUTING.md](CONTRIBUTING.md#adding-a-new-kernel-target) for a
worked example.

## Documentation index

- [ORIGINAL_CONTRIBUTIONS.md](ORIGINAL_CONTRIBUTIONS.md) — what's genuinely ours vs forward-ported, with evidence trail
- [STATUS.md](STATUS.md) — what works / what doesn't
- [CONTRIBUTING.md](CONTRIBUTING.md) — bug reports, patches, upstream plan
- [BUILD_LOG.md](BUILD_LOG.md) — chronological progress
- [checkpoint/docs/PLAN.md](checkpoint/docs/PLAN.md) — current roadmap
- [checkpoint/docs/LEARNINGS.md](checkpoint/docs/LEARNINGS.md) — diagnosis notes
- [checkpoint/docs/research/](checkpoint/docs/research/) — per-iteration reports
- [bootargs/README.md](bootargs/README.md) — kernel cmdline reference

## Reference repos (cloned to `tmp/`, gitignored)

| Repo | Branch | Role |
|---|---|---|
| crashniels-6.15 | `ps4-linux-6.15.y-baikal` | 6.x patch source |
| feeRnt-5.4.247-baikal | `5.4.247-baikal-dfaus` | 5.4 patch source + MT7668 vendor driver |
| feeRnt-6.15.4-BaikalLove | `x_exp__6.15.4-BaikalLove` | alternate 6.15 reference |
| rmuxnet-12xx-current | various | sky2 + xhci experimental fixes |
| baikal-bringup | various | Aeolia/Belize/Baikal southbridge reference |
| whitehax0r-5.4-baikal | `main` | original 5.4 squashed Baikal port |
| vanilla-5.4.247 / vanilla-6.15.4 | upstream tags | clean baselines for diffing |

## Credits

- **whitehax0r** — original PS4 Baikal 5.4 port
- **DFAUS / feeRnt** — 5.4.247 refinement, MT7668 driver, build infra
- **crashniels** — 6.15 forward-port (the heavy lifting for 6.x)
- **rmuxnet** — sky2 + xhci experimental fixes
- **fail0verflow** — original PS4 Linux work and tooling
- **psxitarch project** — Arch-based PS4 Linux distro we boot into

### Tooling

Much of the code in this repository — patches, build scripts, docs, and
debugging analysis — was written collaboratively using
[Claude Code](https://claude.com/claude-code), Anthropic's CLI agent for
software engineering. Specifications, diagnoses, and architectural decisions
were directed by the human maintainer; Claude implemented the mechanical
work (patch generation, build automation, log analysis, infrastructure
scaffolding) under that direction.

## Licensing

### Default — GPL-2.0

The bulk of this repository is GPL-2.0, matching the Linux kernel itself.
This includes:

- All kernel patches under `patches/`
- The patched kernel sources written into `src/<target>/` at build time
- Build scripts, configs, and documentation, unless an individual file says otherwise

See [LICENSE](LICENSE) for the full GPL-2.0 text.

### Vendor firmware blobs — vendor licenses, not GPL

When you build a kernel from this tree, certain proprietary firmware blobs
are loaded at runtime from `/lib/firmware/` on the target system (Sony's
Liverpool/Gladius GPU microcode, Marvell wireless firmware, MediaTek SDIO
firmware). These blobs are **not** part of this repository and **not**
covered by GPL-2.0 — they are redistributed by their respective vendors
under their own license terms. We do not ship them; you obtain them
yourself from the PS4 firmware extraction or each vendor's release.

If you build prebuilt images for redistribution, take care to either
exclude these blobs or ensure your distribution complies with each
vendor's license.

### MediaTek MT7668 wireless driver — Dual BSD-3 / GPL-2.0

The vendor driver under `drivers/net/wireless/mediatek/mt76x8/` is
distributed by MediaTek under a dual BSD-3-Clause / GPL-2.0 license. It
was originally imported from feeRnt's 5.4 baseline and adapted for newer
kernels via cherry-picks credited in `patches/6.x-baikal/series`. Inside
that subtree, individual files retain their original headers — consult
those for per-file specifics. Outside that subtree, GPL-2.0 applies.

### In short

- This repo by default → **GPL-2.0**
- Runtime firmware blobs → **vendor licenses, not bundled here**
- `mt76x8/` subtree → **dual BSD-3 / GPL-2.0** per file headers
