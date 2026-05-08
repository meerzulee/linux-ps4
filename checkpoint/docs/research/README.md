# PS4 Linux — research notes

Notes on the broader upstream PS4 Linux ecosystem, gathered while
deciding how to forward-port our Baikal kernel and what to cherry-pick
from neighbouring efforts.

These are different from `checkpoint/docs/study/`:

- `study/` is the "stop and learn the system" track (in-order reading
  to understand our own patches and the boot chain).
- `research/` (this directory) is what we know about **other people's
  trees**, **why** we know it, and **what it means for our work**.

## Reading order

| # | File | What it covers |
|---|------|----------------|
| 1 | [upstream-survey.md](upstream-survey.md) | Map of the upstream PS4 Linux ecosystem: feeRnt, rmuxnet, crashniels, codedwrench, fail0verflow lineage. Branch landscape across each repo. Console-model / southbridge / kernel-version compatibility matrix. |
| 2 | [arabpixel-loader.md](arabpixel-loader.md) | The PS4 Linux loader (`ArabPixel/ps4-linux-payloads`) v24b — what it actually does between Orbis/FreeBSD and our kernel. Important findings about MSI/IOMMU disable, BAR addresses, the `sb_id` handoff. |
| 3 | [rmuxnet-bringup-analysis.md](rmuxnet-bringup-analysis.md) | File-by-file analysis of `rmuxnet/ps4-linux-12xx` `rmux/baikal/bringup` branch (12-commit clean Baikal port). The architectural reference for what a clean, layered Baikal patch series looks like. |
| 4 | [gap-analysis-vs-our-tree.md](gap-analysis-vs-our-tree.md) | What's in our `linux-ps4/` patches vs upstream. Where the gaps are (sky2 storm fix, HPET stop, sb_id boot_param fast-path). Recommended cherry-picks ranked by leverage. |
| 5 | [2026-05-08-6x-breakthrough.md](2026-05-08-6x-breakthrough.md) | The session that made 6.x boot to `/init`. UART-log walkthrough of the successful boot, the bpcie_uart cascade diagnosis, and the path forward. |

## How these were assembled

Written 2026-05-08 in `~/Work/ps4/research/` (a working scratchpad that
lives outside this repo) and moved here once the analysis stabilised.
The original `research/` directory still contains the working artifacts:

- `~/Work/ps4/research/baikal-bringup/` — shallow clone of rmuxnet's
  `rmux/baikal/bringup` branch (~1.2 GB, regenerable via
  `gh repo clone rmuxnet/ps4-linux-12xx -- --branch rmux/baikal/bringup --single-branch --depth 15`).
- `~/Work/ps4/research/arabpixel-payloads/` — shallow clone of the
  ArabPixel loader source (~26 MB).
- `~/Work/ps4/research/build/` — clean-room 6.x build workspace (~5 GB
  with src/ unpacked; `output/` has the working bzImage). The
  reproducible build scripts (`install-to-usb.sh`,
  `update-bootargs.sh`) have been generalised and moved to
  `linux-ps4/scripts/dev/`.

If `research/` doesn't exist on a fresh checkout, none of the docs
above need it to be useful — the references are mostly informational.
Recreate any of the clones above only when you want to do new analysis
or a new clean-room build.

## Working artifacts in this repo

The patches identified by these analyses are staged under their natural
homes:

- [`patches/feeRnt-6.15.4-BaikalLove/`](../../../patches/feeRnt-6.15.4-BaikalLove/) — feeRnt's recent 6.15 Baikal experiment, 10 patches extracted standalone.
- [`patches/rmuxnet-7.0-baikal/`](../../../patches/rmuxnet-7.0-baikal/) — rmuxnet's `ps4-baikal-7.0-port` branch, 8 patches extracted standalone.
- [`patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate`](../../../patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate) — extracted PS4 quirks from rmuxnet's `rmux/sky2/experimental-fixes` `45f6ad09`. Likely fixes "Ethernet over Baikal sky2 — broken" per LEARNINGS.md.

## Captured boot logs from the session

- [`../uart-boot-2026-05-08-6x-keep_bootcon-success.log`](../uart-boot-2026-05-08-6x-keep_bootcon-success.log) — 1753 lines of 6.x boot from `kexec: About to relocate` through `Run /init` to the rootfs lookup loop. Companion to `2026-05-08-6x-breakthrough.md`.
- [`../uart-boot-capture-ttyS0E000.log`](../uart-boot-capture-ttyS0E000.log) — earlier 5.4 boot capture from the UART unlock work (~135 lines, earlycon-to-fbcon window).

## Reference material in the broader repo

- [`../PLAN.md`](../PLAN.md) — current global plan and next-session priority list.
- [`../LEARNINGS.md`](../LEARNINGS.md) — chronological diagnosis history.
- [`../../../BUILD_LOG.md`](../../../BUILD_LOG.md) — chronological build attempts.
- [`../../../bootargs/`](../../../bootargs/) — canonical bootargs reference texts (5.4-normal, 6.x-diagnostic, 6.x-bypass-systemd).
- [`../study/`](../study/) — step-by-step study notes on our own patches.
