# v53 result — inject TX SETUP + SETUP_VSEMPH before ENABLE

**Date:** 2026-05-10
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0027-amdgpu-ps4-tx-setup-vsemph-before-enable.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `8993fc456d47d7571df6485d71f523fc`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1755-v53-tx-setup-vsemph.log` (3202 lines, 232 KB)
**Result:** ❌ Display still dark, BUT TX `final v5` args confirmed coherent
across SETUP/SETUP_VSEMPH/ENABLE. The remaining missing step is **emitting
DP training pattern symbols on the link**.

---

## What v53 added

After v52 (patch 0026) floored `dig_connector->dp_clock=270000` and
`dp_lane_count=4`, the v52 trace showed encoder side now correct but
transmitter ran only DISABLE → ENABLE with no SETUP between. v53:

1. Inject `ATOM_TRANSMITTER_ACTION_SETUP (10)` and
   `ATOM_TRANSMITTER_ACTION_SETUP_VSEMPH (11)` calls before ENABLE in
   `amdgpu_atombios_encoder_setup_dig` (line 1356).
2. Add `final v5/v6 args` trace (showing `ucPhyId`, `usSymClock`,
   `ucLaneNum`, `ucConnObjId`, `ucDigMode`, `ucHPDSel`,
   `ucDigEncoderSel`, `ucDPLaneSet`) right before each transmitter
   `execute_table` call.

---

## What v53 confirmed

The `final v5` dumps for action=10/11/1 are **identical and coherent**:

```
dig_tx final v5: action=10 phyId=0x00 symClk=27000 laneNum=4 connObj=0x13 digMode=0 hpdSel=1 digEncSel=0x01 dpLaneSet=0x00
dig_tx final v5: action=11 phyId=0x00 symClk=27000 laneNum=4 connObj=0x13 digMode=0 hpdSel=1 digEncSel=0x01 dpLaneSet=0x00
dig_tx final v5: action=1  phyId=0x00 symClk=27000 laneNum=4 connObj=0x13 digMode=0 hpdSel=1 digEncSel=0x01 dpLaneSet=0x00
```

Decoded:
- `phyId=0x00` = `ATOM_PHY_ID_UNIPHYA` (atombios.h:1496) — first UNIPHY
  block. Matches Sony's VBIOS object info for the bridge wiring.
- `symClk=27000` = 270 MHz link symbol clock (2.7 Gbps)
- `laneNum=4` = 4 lanes
- `connObj=0x13` = HDMI connector object ID
- `digMode=0` = `ATOM_ENCODER_MODE_DP`
- `hpdSel=1` = HPD #1
- `digEncSel=0x01` = DIG block 0 (1 << 0)
- `dpLaneSet=0x00` = voltage swing 0, pre-emphasis 0 (default training start)

All three actions see the same coherent state. **The transmitter is
fully and correctly configured.**

---

## Marker tally

| Marker | v52 | v53 |
|---|---|---|
| `floor dig_connector dp_clock=270000 dp_lane_count=4` | 1 | 1 |
| `forcing TX SETUP + SETUP_VSEMPH before ENABLE` | n/a | **1 ✅** |
| `dig_tx action=10 (SETUP)` | 0 | **1 ✅** |
| `dig_tx action=11 (SETUP_VSEMPH)` | 0 | **1 ✅** |
| `dig_tx action=1 (ENABLE)` | 1 | 1 |
| `dig_tx final v5: action=...` | 0 | **3 ✅** (one per action) |
| Bridge `cq_wait_set` (`enable BEGIN`→`cq_exec=20`) | 3.0 s | **3.0 s (unchanged)** |
| Screen | dark | dark |

---

## Boot timing milestones (modeset cycle)

| t (s) | Event |
|---|---|
| 15.132 | `floor dig_connector` + `AdjustDisplayPll` + `SetPixelClock` (350 µs) |
| 15.133 | `bridge_pre_enable: BEGIN` |
| 15.141 | `dig_encoder action=0x0f (SETUP)` |
| 15.141 | `dig_encoder action=0x10 (PANEL_MODE)` |
| 15.141 | **`forcing TX SETUP + SETUP_VSEMPH before ENABLE`** |
| 15.141 | `dig_tx action=10 (SETUP)` ← v53 NEW |
| 15.141 | `dig_tx action=11 (SETUP_VSEMPH)` ← v53 NEW |
| 15.141 | `dig_tx action=1 (ENABLE)` |
| 15.142 | `dig_encoder action=0x0d (DP_VIDEO_ON)` |
| 15.143 | `bridge_enable: BEGIN` |
| **18.110** | **`cq_exec=20`** (3.0 s `cq_wait_set` hang persists) |
| 18.825 | `bridge_enable: END` |

---

## What's left — emit DP training pattern on the link

Looking at the canonical AMD DP path (`atombios_dp.c::amdgpu_atombios_dp_link_train`),
the trainer emits **TPS1/TPS2 patterns** on the link via:

```
ATOM_ENCODER_CMD_DP_LINK_TRAINING_START       (0x08)  — begin TPS1
ATOM_ENCODER_CMD_DP_LINK_TRAINING_PATTERN1    (0x09)
ATOM_ENCODER_CMD_DP_LINK_TRAINING_PATTERN2    (0x0a)
ATOM_ENCODER_CMD_DP_LINK_TRAINING_COMPLETE    (0x0b)
ATOM_ENCODER_CMD_DP_VIDEO_ON                  (0x0d)
```

In our v53 path we go directly from `TX ENABLE` → `DP_VIDEO_ON`. The
transmitter is "ENABLED" but it's idle: never told to emit TPS1 or
TPS2. The MN864729 bridge polls `cq_wait_set` for DP lane lock and
sees no signal toggles.

`amdgpu_atombios_dp_link_train` normally runs the LINK_TRAINING_*
actions interleaved with DPCD reads (which patch 0006 disables because
the bridge's fake DPCD doesn't respond). But the **source-side
actions** are independent of DPCD — they tell the GPU's encoder to
emit specific bit patterns. The bridge's MN864729 has its own
internal training over ICC; it just needs SOMETHING on the link.

---

## v54 plan — source-only DP training pulse

Replace patch 0006's bare `return;` for Liverpool/Gladius in
`amdgpu_atombios_dp_link_train` with a call to a new helper
`amdgpu_atombios_dp_ps4_source_train(encoder)` that emits:

```c
LINK_TRAINING_START → mdelay(5) →
LINK_TRAINING_PATTERN1 → mdelay(5) →
LINK_TRAINING_PATTERN2 → mdelay(5) →
LINK_TRAINING_COMPLETE → mdelay(1) →
return
```

No DPCD reads. Pure source-side. Patch 0006 conceptually changes from
"return immediately" to "source-only train, no DPCD reads". This is
located inside `dp_link_train` rather than `setup_dig` so the
encoder DPMS sequencing stays unchanged (TX ENABLE → link_train() →
DP_VIDEO_ON → bridge_enable).

Predictions:
- `cq_wait_set` 3-s hang collapses to <500 ms if the bridge needs link
  symbols to lock.
- HDMI lights up.
- If still dark but timing changes, bridge is now seeing some link
  activity (fallback test for v55: hold TPS2 during bridge_enable).

---

## Reference paths

- This patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0027-amdgpu-ps4-tx-setup-vsemph-before-enable.patch`
- Active fixes: `…/0022, 0023, 0026` (floors + clobber)
- Active traces: `…/0021, 0024, 0025` (ATOM args + table tracer + dig args/PIXCLK)
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1755-v53-tx-setup-vsemph.log`
- v52 result: `linux-ps4/checkpoint/docs/research/…2026-05-10-v52-floor-dig-connector-result.md`
