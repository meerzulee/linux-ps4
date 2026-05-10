# v58 result — step-by-step DP lane-status probe (THE LOCALIZER)

**Date:** 2026-05-10
**Patch:** `0030-amdgpu-ps4-step-by-step-lane-status-probe.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `719624dd0c70878dc0ffd35973492a7b`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1924-v58-step-by-step-probe.log`
**Result:** **DEFINITIVE LOCALIZATION** — TX DISABLE (action=0) identified as the singular killer.

## What v58 added

A new public helper `ps4_bridge_probe_lane_status(const char *tag)` in
`ps4_bridge.c` that reads bridge registers `0x60f8` (DP RX lane lock) and
`0x60f9` (DP RX link state) via `cq_init+cq_read+cq_exec` and prints both
with a caller-supplied tag. Calls inserted at strategic points in
`atombios_crtc.c` (before/after AdjustDisplayPll, after SetPixelClock)
and `atombios_encoders.c` (after each `setup_dig_encoder` action,
before+after each `setup_dig_transmitter` action).

## The smoking gun (probe timeline)

```
15.029  before-dig_tx-action=7 (INIT)        f8=0xff f9=0x1b   ← BIOS lock OK
15.094  after-dig_tx-action=7  (INIT)        f8=0xff f9=0x1b   ← INIT preserves
15.520  before-AdjustDisplayPll              f8=0xff f9=0x1b   ← still locked
15.540  after-AdjustDisplayPll               f8=0xff f9=0x1b   ← AdjustDisplayPll innocent
15.561  after-SetPixelClock                  f8=0xff f9=0x1b   ← SetPixelClock innocent
15.580  after-DP_VIDEO_OFF                   f8=0xff f9=0x1b   ← DP_VIDEO_OFF innocent
15.600  before-dig_tx-action=0 (TX DISABLE)  f8=0xff f9=0x1b   ← still locked
15.620  after-dig_tx-action=0  (TX DISABLE)  f8=0x9f f9=0x1a   ← *** DISABLE BROKE IT ***
15.640  after-SETUP                          f8=0x9f f9=0x1a
15.650  after-PANEL_MODE                     f8=0x9f f9=0x1a
15.670  after-dig_tx-action=1  (TX ENABLE)   f8=0x9f f9=0x1a   ← ENABLE doesn't restore
15.680  after-DP_VIDEO_ON                    f8=0x9f f9=0x1a
```

## Falsified suspects

| Step | Result |
|---|---|
| AdjustDisplayPll | innocent (f8 preserved) |
| SetPixelClock (PPLL2) | innocent (f8 preserved) |
| DP_VIDEO_OFF | innocent (f8 preserved) |
| dp_set_rx_power_state(D3) | innocent (pre-DISABLE probe still 0xff) |
| **TX DISABLE** | **GUILTY — `f8: 0xff → 0x9f` exactly here** |
| TX ENABLE | secondary — does not restore lock |
| DP_VIDEO_ON | not tested on intact lock (already broken by DISABLE) |

## Significance

Six iterations (v52-v57) of guess-and-bisect couldn't pin down the killer because the bridge probe only samples at chunk-A time, after multiple modeset steps had already run. v58's intra-modeset sampling resolved that ambiguity in a single boot.

## v59 plan derived from v58

Skip the destructive `setup_dig_transmitter(DISABLE)` call on Liverpool/Gladius DP. Predicted partial-win: f8 stays 0xff through DP_VIDEO_OFF/SETUP/PANEL_MODE, but TX ENABLE may also disturb it (open question). If yes, v60 also gates ENABLE.

## Reference paths

- Patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0030-amdgpu-ps4-step-by-step-lane-status-probe.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1924-v58-step-by-step-probe.log`
- v55 chunk-split (made the localizer possible): `…/0029-amdgpu-ps4-bridge-cq-instrumentation-chunk-split.patch`
- v59 partial-fix: `…2026-05-10-v59-skip-tx-disable-result.md`
- v60 breakthrough: `…2026-05-10-v60-skip-tx-enable-result.md`
