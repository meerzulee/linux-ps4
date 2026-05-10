# v51 result — trace setup_dig_transmitter/encoder args + PIXCLK_RESYNC dump

**Date:** 2026-05-10
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0025-amdgpu-ps4-trace-dig-tx-encoder-pixclk.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `9092930cff1124092ae2a2326b3399f0`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1729-v51-dig-tx-encoder-pixclk.log` (3141 lines, 227 KB)
**Result:** ❌ Display still dark, but **the actual root cause is now isolated.** DP transmitter is being enabled with `lane_count=0` and `dp_clock=0`. The v47 floor (patch 0022) only updates a *local* variable; it doesn't propagate to the connector fields that `setup_dig_transmitter` and `setup_dig_encoder` read.

---

## What v51 was

After v50 traced every ATOM table and showed `UNIPHYTransmitterControl
(idx 0x4c)` and `DIGxEncoderControl (idx 0x04)` running cleanly with
`ret=0` despite a dark screen, three candidates remained:

- **H1** wrong args to encoder/transmitter calls
- **H2** PIXCLK_RESYNC routing not picking up PPLL2
- **H3** skip-DP-link-train starves the bridge of TPS pattern

H1 + H2 are pure visibility. v51 instrumented them in one patch. H3
was deferred (behavior change, save attribution clean).

Three additions, all gated on `CHIP_LIVERPOOL/CHIP_GLADIUS`:

1. `atombios_encoders.c::amdgpu_atombios_encoder_setup_dig_encoder` —
   pre-execute print of action, frev/crev, encoder_id, dig_encoder,
   pixel_clock, dp_clock, dp_lane_count, hpd_id.
2. `atombios_encoders.c::amdgpu_atombios_encoder_setup_dig_transmitter` —
   pre-execute print of action, frev/crev, encoder_id, dig_encoder,
   pll_id, is_dp, dp_clock, dp_lane_count, lane_num, lane_set,
   connector_object_id, hpd_id.
3. `dce_v8_0.c::dce_v8_0_crtc_mode_set` — post-`set_pll` dump of
   `mmPIXCLK0/1/2_RESYNC_CNTL` plus crtc_id and pll_id.

---

## H2 — PIXCLK_RESYNC routing dump

```
post-SetPixelClock PIXCLK0/1/2 RESYNC: 0x00000000 0x00000001 0x00000000  crtc_id=0 pll_id=1
```

PIXCLK1=0x1, others=0. **Same as v45 BIOS-default state** — ATOM
SetPixelClock did not modify the routing register. May or may not be
correct for DP mode (DP TX is supposed to use the PPLL directly via DIG
config rather than PIXCLK_RESYNC routing). Not the primary blocker.

---

## H1 — encoder/transmitter args (the smoking gun)

The full sequence between `SetPixelClock OUT` and `bridge_pre_enable`
during the second-cycle modeset:

```
[15.083495] SetPixelClock OUT r=0
[15.083498] post-SetPixelClock PIXCLK0/1/2 RESYNC: 0x00000000 0x00000001 0x00000000
[15.083586] dig_encoder action=0x0c (DP_VIDEO_OFF) enc_id=0x001e dig=0 pclk=148500 dp_clk=0 dp_lanes=0 hpd=0
[15.083860] dig_tx      action=0  (DISABLE)        enc_id=0x001e dig=0 pll=1 is_dp=1 dp_clk=0 dp_lanes=0 lane_num=0 lane_set=0x00 conn_obj=0x0013 hpd=0
[15.091457] dig_encoder action=0x0f (SETUP)        enc_id=0x001e dig=0 pclk=148500 dp_clk=0 dp_lanes=0 hpd=0
[15.091496] dig_encoder action=0x10 (PANEL_MODE)   enc_id=0x001e dig=0 pclk=148500 dp_clk=0 dp_lanes=0 hpd=0
[15.091525] dig_tx      action=1  (ENABLE)         enc_id=0x001e dig=0 pll=1 is_dp=1 dp_clk=0 dp_lanes=0 lane_num=0 lane_set=0x00 conn_obj=0x0013 hpd=0
[15.092726] dig_encoder action=0x0d (DP_VIDEO_ON)  enc_id=0x001e dig=0 pclk=148500 dp_clk=0 dp_lanes=0 hpd=0
[15.084344] bridge_pre_enable BEGIN
[15.092969] bridge_enable     BEGIN
[18.060529] cq_exec=20  (3-second cq_wait_set hang)
```

**`dp_clk=0` and `dp_lanes=0` everywhere.** The DP transmitter is
enabled with **zero link clock and zero lanes**. ATOM accepts this and
returns ret=0 (no validation), but the resulting DP signal is dead — no
lanes carrying any clock. The bridge sees nothing.

Other args look correct:
- `enc_id=0x001e` = `ENCODER_OBJECT_ID_INTERNAL_UNIPHY` — first UNIPHY
  block. PS4 wiring matches (the bridge connects via UNIPHY1).
- `dig=0` = DIG block 0. Standard.
- `pll=1` = ATOM_PPLL2. Matches our v49 picker pick.
- `is_dp=1` — yes, DP mode.
- `pclk=148500` — pixel clock 1080p60. Correct.
- `frev=1 crev=4/5` — standard CIK versions.

The actions follow the textbook DP modeset sequence (DISABLE → SETUP →
PANEL_MODE → ENABLE → DP_VIDEO_ON). Action codes are correct. **Only the
link config (`dp_clock`, `dp_lane_count`) is wrong, and the
`lane_num/lane_set` parameters that get derived from them are also
wrong.**

---

## Root cause

`setup_dig_transmitter` and `setup_dig_encoder` both read DP link
configuration directly from `dig_connector->dp_clock` and
`dig_connector->dp_lane_count`:

```c
// atombios_encoders.c:584-586 (in setup_dig_encoder)
dp_clock = dig_connector->dp_clock;
dp_lane_count = dig_connector->dp_lane_count;
hpd_id = amdgpu_connector->hpd.hpd;
```

These connector fields are normally populated by
`amdgpu_atombios_dp_set_link_config(connector, mode)` after a successful
DPCD read. On PS4:

- `ps4_bridge_detect` never runs (it's a connector `.detect` callback
  that DRM helpers don't trigger in our boot path).
- `amdgpu_atombios_dp_set_link_config` is therefore never invoked.
- `dig_connector->dp_clock` and `dig_connector->dp_lane_count` stay at
  their zero-init value.

The v47 fix (patch 0022) floors `dp_clock = 270000` only inside
`amdgpu_atombios_crtc_adjust_pll` as a **local variable** — that's used
to feed ATOM AdjustDisplayPll's input correctly (and v47 confirmed
AdjustDisplayPll then returns `freq=270000`). But the local doesn't
write back to `dig_connector`, so `setup_dig_transmitter` /
`setup_dig_encoder` read zero from the connector field.

Result: PLL programmed correctly for 270 MHz link clock, but the DIG
encoder programmed with 0 lanes at 0 clock. Mismatch. Dead link.

---

## Marker tally

| Marker | Status |
|---|---|
| `flooring dp_clock 0 -> 270000` (v47, atombios_crtc.c local) | ✅ fires |
| `AdjustDisplayPll OUT r=0 freq=270000` | ✅ |
| `SetPixelClock IN ... pll=1 ...` | ✅ |
| `SetPixelClock OUT r=0` | ✅ (350 µs real PLL work) |
| `post-SetPixelClock PIXCLK0/1/2 RESYNC: 0x0 0x1 0x0` | ✅ unchanged from BIOS default |
| `dig_encoder action=0x0c/0x0f/0x10/0x0d ... dp_clk=0 dp_lanes=0` | ❌ **link config zero** |
| `dig_tx action=0/1/7 ... dp_clk=0 dp_lanes=0 lane_num=0` | ❌ **link config zero** |
| Bridge `cq_wait_set` (`enable BEGIN`→`cq_exec=20`) | 3.0 s (unchanged) |

---

## v52 plan — floor `dig_connector->dp_clock` and `dp_lane_count` directly

Single-line fix at the start of `amdgpu_atombios_crtc_adjust_pll`,
right where it accesses `dig_connector`:

```c
if ((adev->asic_type == CHIP_LIVERPOOL || adev->asic_type == CHIP_GLADIUS)
    && dig_connector->dp_clock == 0) {
    pr_info("ps4_atom: floor dig_connector dp_clock=270000 dp_lane_count=4\n");
    dig_connector->dp_clock = 270000;
    dig_connector->dp_lane_count = 4;
}
```

This writes the connector fields once, before they're read downstream.
After v52, all subsequent `setup_dig_transmitter` and
`setup_dig_encoder` calls will see `dp_clock=270000` and
`dp_lane_count=4`, so the DIG encoder gets enabled with 4 lanes @ 2.7
GHz — matching what the PPLL is producing.

The v47 local-variable floor (patch 0022) becomes redundant after v52
(the connector field will be populated by the time `dp_clock =
dig_connector->dp_clock` runs at line 332). It can stay as defensive or
be removed in a future cleanup; functionally harmless.

### Predictions

- v51 trace lines for `dig_encoder` and `dig_tx` should show
  `dp_clk=270000 dp_lanes=4 lane_num=4` (and `lane_set` populated).
- ATOM SetPixelClock execute time stays ~350 µs (PLL programming
  unchanged).
- DIG encoder programming actually wires up 4 lanes at the correct
  clock — DP signal goes live on the link.
- Bridge `cq_wait_set` 3-s hang collapses to <500 ms (lane lock
  acquired).
- HDMI lights up.

If `dp_clk=270000 dp_lanes=4` reaches the encoder/TX correctly but the
bridge still hangs, H3 (skip-DP-link-train) becomes the next test —
revert patch 0006 and let the kernel send TPS1/TPS2 patterns; bridge
might need them.

---

## Reference paths

- This patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0025-amdgpu-ps4-trace-dig-tx-encoder-pixclk.patch`
- Active fixes: `…/0022` (v47 local floor), `…/0023` (v49 dp_extclk clobber)
- Active traces: `…/0021` (v46 ATOM call args), `…/0024` (v50 generic table tracer)
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1729-v51-dig-tx-encoder-pixclk.log`
- v50 result: `linux-ps4/checkpoint/docs/research/2026-05-10-v50-atom-table-tracer-result.md`
