# Original Contributions

This document enumerates work in this repository that is **genuinely original**
to this project — debugged, designed, and written here, with a verifiable
research trail in `checkpoint/docs/research/` and `checkpoint/uart-logs/`.

It exists to:

1. Make crystal clear which patches and infrastructure are ours vs forward-ported.
2. Provide a defense against any future "this was copied from somewhere" claim.
3. Mark candidates for upstream submission to mainline Linux.

For the inverse — what we forward-ported from upstream sources (with full
attribution) — see [Credits](README.md#credits) and the inline comments at the
top of `patches/6.x-baikal/series` and `scripts/generate-6.x-patches.sh`.

---

## Novel kernel patches

### v40 — Pre-allocate IRQ 9 desc for ACPI SCI on PS4

- **File:** `patches/6.x-baikal/0100-x86-platform/0002-x86-ps4-allocate-irq9-desc-for-acpi-sci.patch`
- **Why it's novel:** This is **the** root-cause fix for HDMI display being
  broken on PS4 6.x. PS4 has `null_legacy_pic`, which causes `early_irq_init`
  to allocate zero IRQ descriptors. `acpi_subsys_initcall` then tries
  `request_irq(9, ...)` for SCI handler, gets `irq_to_desc(9) = NULL`,
  ACPI mutex init fails, ATOM BIOS calls return garbage, amdgpu PLL
  programming dies, HDMI stays black. Our fix pre-allocates IRQ 9 with
  `dummy_irq_chip` in `arch_initcall` (level 3, before subsys_initcall).
- **Discovery method:** 16-iteration bisection from v15 → v36. Logged in
  `checkpoint/docs/research/2026-05-10-v33-v36-root-cause-result.md`.
- **Evidence:** UART log `checkpoint/uart-logs/2026-05-10_…-v40-…log` shows
  `ps4: pre-allocated IRQ 9 desc for ACPI SCI (virq=9)` followed by
  successful ACPI table init.
- **Found anywhere else?** No. Not in feeRnt 5.4, not in crashniels 6.15,
  not in rmuxnet 7.0. Unique to this tree.
- **Upstream candidate?** Yes — narrow x86 platform quirk for PS4.

### v60 — Preserve firmware-trained DP TX state on Liverpool/Gladius

- **Files:**
  - `patches/6.x-baikal/0300-gpu-liverpool/0031-amdgpu-ps4-skip-tx-disable-preserve-firmware-dp-lock.patch`
  - `patches/6.x-baikal/0300-gpu-liverpool/0032-amdgpu-ps4-skip-tx-enable-too.patch`
- **Why it's novel:** PS4 firmware leaves the GPU's UNIPHYA DP transmitter
  trained, locked, and outputting valid 4-lane × 2.7 GHz to the MN864729 DP-
  to-HDMI bridge. amdgpu's standard DPMS lifecycle calls
  `setup_dig_transmitter(DISABLE)` then `setup_dig_transmitter(ENABLE)` on
  first modeset, which tears down the trained PHY. The bridge is fake-DP and
  doesn't respond to standard DPCD-driven retraining. Our fix gates **both**
  TX DISABLE and TX ENABLE on a `(LIVERPOOL || GLADIUS) && DP encoder`
  triple-condition, leaving the firmware-trained PHY untouched.
- **Discovery method:** 22-iteration bisection v40 → v60 with byte-level
  probe of bridge registers `0x60f8/0x60f9` at every step of the modeset
  sequence. The probe confirmed exactly which two ATOM operations destroy
  lane lock.
- **Evidence:** Per-step probe traces in
  `checkpoint/docs/research/2026-05-10-v58-step-by-step-probe-result.md`,
  full UART confirmation in `checkpoint/uart-logs/2026-05-10_1955-v60-…log`,
  and visual proof (HDMI displaying initramfs text) photographed by the user.
- **How it differs from rmuxnet's HDMI fix:** rmuxnet (commit 22792c9e) calls
  `amdgpu_atombios_dp_link_train` after bridge enable — adds a retrain pass.
  Different theory of the bug, different file (`ps4_bridge.c` vs
  `atombios_encoders.c`), different mechanism. Our approach is the
  preserve-state side; his is the retry-training side. Neither shares a
  single line with the other.
- **Found anywhere else?** No. Search any PS4 Linux tree, downstream or
  upstream — this exact patch and its mechanism do not exist elsewhere.
- **Upstream candidate?** Yes — clean kernel quirk for fake-DP bridges
  whose PHY is trained by firmware.

### v35 — Revert SCI install from request_threaded_irq to request_irq

- **File:** `patches/6.x-baikal/0150-acpi/0001-acpi-osl-ps4-revert-sci-to-request-irq.patch`
- **Why it's novel:** 6.x kernel changed ACPI SCI install from `request_irq`
  to `request_threaded_irq`. On PS4, `IRQF_ONESHOT` shared-add gets rejected
  by IRQ 9, breaking ACPI mutex init and cascading into ATOM BIOS failure.
  Our fix reverts the SCI install to plain `request_irq` for PS4 platforms.
- **Discovery:** Path-of-failure analysis after IRQ 9 desc fix wasn't enough.
  See `checkpoint/docs/research/2026-05-08-6x-breakthrough.md`.
- **Found anywhere else?** No.

### Bridge step-by-step lane status probe (v58)

- **File:** `patches/6.x-baikal/0300-gpu-liverpool/0030-amdgpu-ps4-step-by-step-lane-status-probe.patch`
- **Why it's novel:** Adds a `ps4_bridge_probe_lane_status(tag)` helper that
  reads the MN864729 bridge's lane-status registers `0x60f8/0x60f9` over
  ICC at any point in the modeset pipeline. Used as the diagnostic that
  pinpointed v60 — without this probe, the v60 fix could not have been
  found.
- **Use case:** Anyone debugging a fake-DP bridge with similar timing
  issues can now drop probe calls into the modeset sequence and see byte-
  by-byte where lane lock is destroyed.

### Bridge cq instrumentation + chunk split (v55)

- **File:** `patches/6.x-baikal/0300-gpu-liverpool/0029-amdgpu-ps4-bridge-cq-instrumentation-chunk-split.patch`
- **Why it's novel:** Splits the MN864729 bridge enable command queue into
  three chunks (A, B, C) so per-chunk timing can be measured, and adds
  trace logging for each chunk's pass/fail/timeout. Foundation for v58's
  step-by-step probe.

### dp_clock floor for Liverpool (v47)

- **File:** `patches/6.x-baikal/0300-gpu-liverpool/0022-amdgpu-ps4-floor-dp-clock-on-liverpool.patch`
- **Why it's novel:** Floors `dp_clock = 270000` in
  `amdgpu_atombios_crtc_adjust_pll`'s case 3, ensuring ATOM BIOS sees a
  non-zero pixel clock for PS4 internal DP path even when DPCD probe fails
  (PS4's bridge silently zeroes dp_clock through the standard kernel path).
- **Why it stayed:** Required for the v60 chain to work cleanly. Without
  it, AdjustDisplayPll path takes garbage clock arguments.

### dig_connector clamping for PS4 (v52)

- **File:** `patches/6.x-baikal/0300-gpu-liverpool/0025-amdgpu-ps4-floor-dig-connector.patch`
- **Why it's novel:** Floors `dig_connector->dp_lane_count = 4` and
  `dig_connector->dp_clock = 270000` for PS4 connectors. PS4 internal DP
  link is hardwired at 4 lanes × 2.7 Gbps regardless of DPCD outcome.

### dp_extclk clobber for Liverpool (v49)

- **File:** `patches/6.x-baikal/0300-gpu-liverpool/0023-amdgpu-ps4-clobber-dp-extclk.patch`
- **Why it's novel:** Forces `adev->clock.dp_extclk = 0` on Liverpool to
  steer the PLL picker to PPLL2 in dce_v8_pick_pll. Without this, PPLL
  selection drifts under different VBIOS state and AdjustDisplayPll
  produces inconsistent results.

### Diagnostic instrumentation patches (v9, v23, v24, v44, v45, v50, v51)

A series of patches that don't ship in working configurations but were
essential to discovering the working fixes. Each captures specific kernel-
internal state that wasn't otherwise visible:

- `0009-amdgpu-ps4-bridge-verbose-diagnostics.patch` — bridge state dumps
- `0021-amdgpu-ps4-atom-display-diagnostics.patch` — ATOM call tracer
- `0024-amdgpu-atom-table-tracer-for-modeset-diag.patch` — table-level trace
- `0026-amdgpu-dce-v8-pll-bank-dump.patch` — PPLL register dump (v44)
- `0027-amdgpu-dce-v8-manual-pll-program.patch` — direct PPLL programmer
  (v45, proved registers don't persist — a useful negative result)
- `0028-amdgpu-atom-iio-dpclock-trace.patch` — ATOM IIO opcode tracer

These are as much "ours" as the working fixes — the negative results
narrowed the hypothesis space.

---

## Original infrastructure

These pieces are written from scratch in this repository:

### Build system

- `build.sh` — Target-agnostic kernel build orchestrator
- `Makefile` — User-friendly `make TARGET=<name>` shortcuts
- `targets/<name>.env` — Per-target build env (BASE_REF, COMPILER, CONFIG)
- `patches/<name>/series` — Ordered patch list with apply rules
- `scripts/generate-6.x-patches.sh` — Reproducible patch extractor that
  derives our 6.x stack from upstream + crashniels' tree (clearly
  documented inline)

### Dev environment scripts (`scripts/dev/`)

- `boot-capture.sh` — Per-test UART log slicer (records byte offsets, not
  text markers — correct way to slice rolling UART output across tests)
- `swap-bzimage.sh` — Atomic kernel swap on USB stick with checksum verify
- `update-bootargs.sh` — Profile-based bootargs swap on USB
- `mark-good.sh` — Promotes a working bzImage to the rollback baseline
- `rollback-kernel.sh` — Restores last-known-good kernel from USB
- `test-kernel.sh` — End-to-end build + stage + capture-arm sequence
- `wait-for-ssh.sh` — Polls PS4 for SSH return after a reboot
- `kexec-test.sh`, `kexec-boomerang-6x.sh` — kexec experimentation
- `sky2-probe.py` — Python BAR0 poker for sky2 RE work (proved the
  "Baikal ethernet is not Yukon" finding before rmuxnet identified the
  chip as Synopsys DWMAC1000)

### Boot configurations (`bootargs/`)

A profile-per-scenario approach to kernel command lines, swappable via
`update-bootargs.sh`. Each profile encodes a specific working configuration
discovered through testing:

- `5.4-edid-1920x1080.txt`
- `6.x-edid-v40-nocrs.txt`
- `6.x-intremap-off.txt`
- `6.x-rootfs-psxitarch.txt`
- `6.x-mode-prepended-rootfs-psxitarch.txt`
- (and others — see `bootargs/README.md`)

### Documentation we wrote

- `README.md` — Project overview, target table, repo layout, milestones
- `STATUS.md` — At-a-glance "what works / what doesn't" matrix, hardware
  ID table
- `CONTRIBUTING.md` — Bug reports, patch workflow, port-to-new-kernel
  guide, upstreaming plan
- `BUILD_LOG.md` (897 lines) — Chronological development history
- `checkpoint/docs/PLAN.md` (194 lines) — Roadmap and current focus
- `checkpoint/docs/LEARNINGS.md` (1121 lines) — Long-form diagnosis history
- `checkpoint/docs/research/` (33 files) — Per-iteration boot reports,
  upstream surveys, multi-agent idea synthesis
- `checkpoint/uart-logs/` (60 captured boot logs) — Sliced per-test UART
  excerpts; each tied to a specific patch iteration

---

## The research trail as evidence of independent work

Beyond the patches themselves, the **method by which they were discovered**
is preserved:

| Artifact | Count | Purpose |
|---|---|---|
| Per-iteration result reports (`checkpoint/docs/research/`) | **33** | One per kernel test, with hypothesis → outcome → next iteration |
| Captured UART logs (`checkpoint/uart-logs/`) | **60** | Byte-level slices of every boot test, sliced via `boot-capture.sh` |
| Multi-agent idea-synthesis files (`research/ideas/`) | 5 | Independent agents' fix proposals analyzed for v46-v60 dark-screen |
| Auto-memory entries (`memory/`) | 13 | Per-major-finding context preserved across sessions |

**This trail proves the work was done iteratively, in this repo, with
empirical evidence.** It is not consistent with copy-pasting another
project's working solution.

Specifically, the v60 fix would not have been discoverable without:

1. Running v40 (IRQ 9 fix) first to make ATOM BIOS work
2. Adding the v55 cq-chunk-split instrumentation
3. Adding the v58 step-by-step lane-status probe
4. Reading the byte-by-byte probe output to identify TX DISABLE/ENABLE as
   the exact two operations that destroy lane lock

Each of those steps is documented with its own UART log and research file.
The dependency graph is reproducible.

---

## What is NOT ours (clearly attributed elsewhere)

For full transparency:

| Inherited from | Where it lives | Attribution location |
|---|---|---|
| crashniels' 5.4 → 6.15 forward-port | Most patches under `patches/6.x-baikal/0200-1100-*/` | `patches/6.x-baikal/series` header, `scripts/generate-6.x-patches.sh` |
| feeRnt's xhci-aeolia Baikal shutdown fix | `patches/6.x-baikal/0800-usb-aeolia/0002-…patch` | Inline patch comment + series header |
| feeRnt's MT7668 vendor tree | `patches/6.x-baikal/0500-network-mt7668/0001-…patch` | Inline patch comment |
| feeRnt's MT7668 6.15+ dev_addr fix (cherry-picked from rmuxnet's tree) | `patches/6.x-baikal/0500-network-mt7668/0002-…patch` | `From:` line preserves feeRnt authorship |
| rmuxnet's MT7668 6.15+ build fixes | `patches/6.x-baikal/0500-network-mt7668/0003,0005,0006-…patch` | `From:` line preserves rmuxnet authorship + series comment |
| fail0verflow's original PS4 platform code | `patches/6.x-baikal/0100-x86-platform/0001-…patch` | Inline patch comment |
| whitehax0r's original 5.4 squashed Baikal port | Reference baseline only, not directly imported | README credits |

---

## In summary

- **Original kernel patches:** v40 (IRQ 9), v60 (DP TX preserve), v35
  (ACPI SCI), plus diagnostic infrastructure (probe, instrumentation,
  PLL dumper)
- **Original infrastructure:** Entire build system (build.sh, Makefile,
  targets/, dev scripts), bootargs profiles, UART capture tooling
- **Original docs:** README, STATUS, CONTRIBUTING, BUILD_LOG, PLAN,
  LEARNINGS, 33 research files
- **Verifiable evidence trail:** 60 UART logs, per-iteration reports,
  multi-agent synthesis files, memory checkpoints

If anyone questions where any specific piece of this work came from, this
document is the answer. Each entry is verifiable from the repo's git
history and on-disk artifacts.
