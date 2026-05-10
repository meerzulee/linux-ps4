# Contributing to PS4 Linux

Welcome — this project welcomes outside contributions. Whether you're
debugging a driver, porting to a new kernel version, fixing a regression,
or working toward upstream submission, this doc explains how the project
is organized and how to land work.

## Quick reference

- Found a bug? → [open an issue](https://github.com/meerzulee/linux-ps4/issues)
- Have a fix? → see [Submitting patches](#submitting-patches)
- Want to port to a new kernel? → see [Adding a new kernel target](#adding-a-new-kernel-target)
- Want your patch in mainline? → see [Upstreaming](#upstreaming)

## How the build works

Each kernel target is a single env file plus a series of patches.

```
targets/6.x-baikal.env       # BASE_REF=v6.15.4, COMPILER=gcc, CONFIG=config/6.x-baikal.config
patches/6.x-baikal/series    # ordered list of patch filenames
patches/6.x-baikal/0XXX-*/   # patches bucketed by subsystem
config/6.x-baikal.config     # full kernel .config
```

`build.sh` clones the upstream tag specified by `BASE_REF`, applies the
patch series in order, copies the config, and runs `make`. There's no
hidden state — every kernel we ship is reproducible from this repo plus
the upstream Linux git mirror.

## Bug reports

A useful bug report includes:

1. **Hardware**: PS4 model (CUH-####), motherboard revision (`PSFree → about`)
2. **Kernel version + commit**: `uname -a` from inside Linux, plus the commit/tag of this repo you built
3. **Bootargs**: contents of `bootargs.txt` on your USB
4. **UART log**: `checkpoint/uart-logs/...` excerpt from boot-capture.sh, or copied from the live UART. Trim to the relevant ~50 lines.
5. **What you expected vs. what happened**

A *non*-useful bug report is "doesn't boot" with no log — we can't help
without UART output.

## Submitting patches

We use a patch-stack model (every change is a file under `patches/<target>/`).
Workflow:

### 1. Make your change

Edit the kernel source under `src/<target>/...` directly. The next
build will wipe untracked changes via `git clean -fd`, so save state
as a patch before rebuilding.

### 2. Generate a patch

The simplest reliable way is via a snapshot diff:

```sh
# Before editing:
cp -r src/6.x-baikal/<dir-you'll-touch> /tmp/snapshot/

# Edit src/6.x-baikal/...

# Generate the patch:
diff -urN /tmp/snapshot/ src/6.x-baikal/<dir-you'll-touch>/ \
  | sed 's|^\(--- /tmp/snapshot/\)|--- a/<dir-you-touch>/|' \
  | sed 's|^\(+++ src/6.x-baikal/\)|+++ b/|' \
  > patches/6.x-baikal/0XXX-mysubsystem/00YY-my-fix.patch
```

Or if you're editing a single existing patch's territory, the
`scripts/dev/` directory has helpers — see existing patch headers in
`patches/6.x-baikal/0300-gpu-liverpool/` for the patch-format convention.

### 3. Verify it builds

```sh
./build.sh -t 6.x-baikal
```

Look for "BUILD COMPLETE" at the end. Patch-apply failures during the
patch step are the most common issue; usually because line numbers
drifted and you need to refresh the surrounding context.

### 4. Test on hardware

Per the [PS4 dev loop](scripts/dev/), this means power-cycling through
PSFree-Enhanced and re-launching `linux-1024mb.bin`. Each test cycle
costs ~5 minutes of the gauntlet, so plan changes carefully.

If you have SSH already (post-v62), kernel-module changes can be hot-
swapped via `scp` + `modprobe -r` + `modprobe` without a reboot.

### 5. Open a PR

- Patch file in `patches/<target>/<subsys>/`
- Series file updated to include the new entry
- Brief PR description: what does the patch do, what bug does it fix,
  evidence (UART log excerpt, `dmesg | grep ...`, etc.)
- Sign your commit: `git commit -s` (matters for upstreaming, see below)

## Adding a new kernel target

Suppose mainline 6.16 ships and you want to port. Worked example:

```sh
# 1. Create env file
cp targets/6.x-baikal.env targets/6.16-baikal.env
# Edit BASE_REF=v6.16.x

# 2. Copy patch series (try as-is first)
cp -r patches/6.x-baikal patches/6.16-baikal

# 3. Copy config
cp config/6.x-baikal.config config/6.16-baikal.config

# 4. First build
./build.sh -t 6.16-baikal -c   # -c for clean (re-clone src tree)

# 5. Triage: any patches that fail to apply because the surrounding
#    code drifted? Refresh them. Any new compile errors from API
#    changes? Fix in the patch directly. Run `make olddefconfig` if
#    config needs updating.

# 6. Boot test, capture UART, document differences in a per-version
#    BUILD_LOG entry.
```

In practice each forward-port is a half-day to a day of patch
refreshing. We've already done this for the 5.4→6.15 jump (see the
v40-v60 work).

## Upstreaming

The long-term goal is to send our cleanest patches to mainline Linux.
Here's the plan and the realistic prospects.

### Patches that are ready to upstream (good candidates)

| Patch | Target subsystem | Maintainer | Notes |
|---|---|---|---|
| **v60 DP TX preserve fix** (`patches/6.x-baikal/0300-gpu-liverpool/0031+0032`) | drm-amd-next | Alex Deucher | Narrow, well-documented, single concept. The patch description in the v60 commit is upstream-quality. |
| **amdgpu Liverpool/Gladius asic_type addition** (`0300-gpu-liverpool/0001+0002`) | drm-amd-next | Alex Deucher | Adds new ASIC table entries; clean. |
| **xhci_aeolia variant** | usb-next | Mathias Nyman | Would need clean separation from PS4-platform glue. |

### Patches unlikely to be accepted as-is

- **bpcie southbridge / ICC / APcie infrastructure** — would need a
  proper `arch/x86/platform/ps4/` subdirectory, MAINTAINERS entry,
  ACPI table parsing, etc. This is a substantial effort but a real
  upstream path. Similar precedent exists for other game consoles in
  Linux (Xbox Original, Wii).

### Patches that won't be upstreamed

- **mt76x8 vendor tree** — it's a vendor blob. Upstream wants drivers
  written against the in-tree `mt76` framework, not vendor SDKs.
  Replacing this with mainline mt76 patches is itself a large project.
- **sky2 Baikal RE work** — we don't have a working driver; nothing to
  submit yet.
- **PS4-specific quirks scattered across many drivers** — some can be
  consolidated; others (e.g., "skip phy reset on Aeolia") are too
  specific to be worth submitting.

### Submission workflow when ready

For each upstream-candidate patch:

1. **Rebase against mainline** — check out the relevant maintainer's
   tree (e.g., `drm-misc-next`, `net-next`), apply the patch on top,
   verify it still builds.
2. **Run `scripts/checkpatch.pl --strict`** in the kernel tree —
   anything that comes back is a stylistic blocker.
3. **Sign the commit**: `git commit -s` adds `Signed-off-by:` line.
4. **Use git format-patch** to generate the email-format patch.
5. **Email the maintainer + LKML + relevant subsystem list**, with
   `[PATCH]` subject prefix and per-version annotations (`[PATCH v2]`
   etc. on subsequent revisions).

Maintainer review can take weeks to months. Be prepared to iterate.

We track upstream progress in
[checkpoint/docs/upstream-status.md](checkpoint/docs/upstream-status.md)
(if/when patches are submitted).

## Development model — drawing inspiration from `linux-g14`

We're modeling this project after the `asus-linux/linux-g14` pattern:

- Single repo, multiple kernel-version targets in parallel
- Patches organized by subsystem, kernel version separable
- CI/CD builds and publishes artifacts on tags (planned, see Phase 2)
- Friendly README + at-a-glance status
- Upstreaming as a first-class long-term goal

If you want to see how a similar community-maintained Linux project is
organized, check out `https://gitlab.com/dragonn/linux-g14` for
reference.

## Conventions

- **Patch filenames**: `0NNN-<short-name>.patch` where `0NNN` is a
  4-digit number sortable in apply order within a subsystem directory.
- **Patch headers**: `From:`, `Subject:` lines + a multi-paragraph
  description explaining *why*. We optimize for "future-Claude / future-you
  reading this 6 months later".
- **Series file**: comments above each patch explaining the version
  number that introduced it, what it fixed, and any disabled/superseded
  state. Disabled patches stay in the file as `# patches/...patch`.
- **Boot logs**: stored in `checkpoint/uart-logs/<DATE>_<TIME>-<name>.log`,
  generated by `scripts/dev/boot-capture.sh stop <name>`.
- **Per-iteration reports**: `checkpoint/docs/research/<DATE>-<name>-result.md`,
  one per significant kernel iteration.

## License

By submitting code, you agree it can be relicensed under GPL-2.0
(matching the Linux kernel). For non-code contributions (docs,
configs), GPL-2.0 also applies unless otherwise noted.

## Communication

- **Issues**: bug reports, feature requests, port requests
- **Discussions**: design questions, hardware investigations
- **Pull requests**: code

Don't be shy. PS4 Linux is a niche project — every contributor matters.
