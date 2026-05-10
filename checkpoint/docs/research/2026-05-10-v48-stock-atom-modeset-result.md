# v48 result — disable v44/v45 short-circuit, restore stock ATOM modeset

**Date:** 2026-05-10
**Change:** `patches/6.x-baikal/series` — comment out `0019-amdgpu-dce-v8-liverpool-preserve-bios-pll.patch` and `0020-amdgpu-dce-v8-liverpool-manual-pll-program.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `873735d17512e23759311f728e3bef40`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1624-v48-stock-atom-modeset.log` (2684 lines, 185 KB)
**Result:** ❌ Display still dark, but **major progress** — both ATOM calls now succeed cleanly, and the *new* failure point is precisely identified: `pll_id=255` (ATOM_PPLL_INVALID) at `SetPixelClock` time means ATOM has nothing to program.

---

## What v48 was

After v47 (patch 0022) confirmed ATOM `AdjustDisplayPll` returns a real
`freq=270000` once `dp_clock` is floored, two patches that bypassed ATOM
became provably wrong:

- `0019-amdgpu-dce-v8-liverpool-preserve-bios-pll.patch` (v44 short-circuit)
- `0020-amdgpu-dce-v8-liverpool-manual-pll-program.patch` (v45 manual writes
  to `mmDCCG_PLL_*` — confirmed for the third time as no-op since those
  registers don't store)

v48 disables both in `series` (commented, files left on disk). The v46
trace (patch 0021) and v47 dp_clock floor (patch 0022) stay active.
`dce_v8_0_crtc_mode_set` returns to the stock CIK path:

```
amdgpu_atombios_crtc_set_pll(crtc, adjusted_mode);   // ATOM SetPixelClock
amdgpu_atombios_crtc_set_dtd_timing(crtc, adjusted_mode); // ATOM SetCRTC_UsingDTDTiming
dce_v8_0_crtc_do_set_base(...);                       // framebuffer scanout
```

---

## Marker tally

| Marker | v47 | v48 |
|---|---|---|
| `flooring dp_clock 0 -> 270000` | 1 | 1 |
| `AdjustDisplayPll v1.3 OUT r=0 freq=270000` | 1 | 1 |
| `ATOM returned 0, using adjusted_mode->clock` (v28 fallback) | 0 | 0 |
| **`SetPixelClock IN frev=1 crev=6 ...`** | 0 (skipped) | **1 ✅** (first time this trace ever fires) |
| **`SetPixelClock OUT r=0`** | 0 | **1 ✅** |
| v45 PPLL pre/post dumps (mmDCCG_PLL_*) | 2 dumps | **0 ✅** (0019/0020 disabled) |
| `bridge_enable: BEGIN` → `cq_exec=20` (post-modeset cycle) | 3.0 s | 3.0 s (unchanged) |

---

## Boot timing milestones

| t (s) | Event |
|---|---|
| 12.897 | `Fetched VBIOS from ROM BAR` |
| 12.903 | `ATOM BIOS: 113-Starsha2-018` |
| 13.085 | First `bridge_enable: BEGIN` (force-init from patch 0007) |
| 14.444 | First `cq_exec=20` (1.4 s wait) |
| 14.644 | First `bridge_enable: END` |
| 14.722 | `ps4_bridge_get_modes` |
| 14.729 | `flooring dp_clock 0 -> 270000` |
| 14.729 | `AdjustDisplayPll v1.3 OUT r=0 freq=270000 ref=0 post=0` ✅ |
| **14.729** | **`SetPixelClock IN frev=1 crev=6 crtc=0 clock=148500 pll=255 ref=2 fb=118 frac=8 post=22 enc_id=30 enc_mode=0 bpc=8 ss=1`** |
| **14.729** | **`SetPixelClock OUT r=0`** ✅ (success — but a no-op success because pll=255) |
| 14.735 | Second `bridge_enable: BEGIN` |
| **17.705** | **Second `cq_exec=20`** — 3-s `cq_wait_set` hang persists |
| 18.420 | Second `bridge_enable: END` |
| 18.614 | `[drm] fb0: amdgpudrmfb frame buffer device` |

---

## Decoding the SetPixelClock arguments

```
frev=1 crev=6 crtc=0 clock=148500 pll=255 ref=2 fb=118 frac=8 post=22
enc_id=30 enc_mode=0 bpc=8 ss=1
```

- **`frev=1, crev=6`** → ATOM uses the v6 union variant
  (`PIXEL_CLOCK_PARAMETERS_V6`). v6 layout writes `args.v6.ulDispEngClkFreq`
  (clock + crtc encoded in upper byte), `ucRefDiv`, `usFbDiv`,
  `ulFbDivDecFrac`, `ucPostDiv`, `ucPpll`, `ucTransmitterID`,
  `ucEncoderMode`. See `atombios_crtc.c:673-704`.
- **`crtc=0, clock=148500`** → CRTC 0, target pixel clock 148.5 MHz (1080p60).
- **`pll=255`** = `ATOM_PPLL_INVALID`. **This is the new blocker** — see
  next section.
- **`ref=2 fb=118 frac=8 post=22`** → standard amdgpu PLL math:
  `100 MHz × 118.8 / 2 / 22 = 270.0 MHz` ← that's the **DP link clock**
  (matches our v47 floor of `dp_clock=270000` exactly). Dividers are
  computed correctly by `amdgpu_pll_compute(adev, pll, adjusted_clock=270000, ...)`.
- **`enc_id=30 (0x1e)`** → likely `ENCODER_OBJECT_ID_INTERNAL_UNIPHY` or PS4
  internal DP transmitter ID.
- **`enc_mode=0`** = `ATOM_ENCODER_MODE_DP`. Confirms encoder is in DP mode
  (which is why AdjustDisplayPll consumed `dp_clock` not `mode->clock` for
  its input).
- **`bpc=8, ss=1`** → 8-bit color, spread-spectrum enabled.

The dividers are valid for 270 MHz output; they're just being passed to
ATOM along with `ucPpll=ATOM_PPLL_INVALID`, and ATOM's v6 SetPixelClock
bytecode bails when `ucPpll == 0xFF`.

---

## Why the screen is still dark — `pll_id=255`

`pll=255` (`ATOM_PPLL_INVALID`) is set somewhere in `amdgpu_crtc->pll_id`,
most likely by `amdgpu_atombios_crtc_prepare_pll` calling
`amdgpu_pll_pick_pll_id(adev, encoder, ...)`. For CIK with DP encoders,
the picker is allowed to return `ATOM_PPLL_INVALID` when the DP
transmitter is expected to use its own clock source (e.g. DCPLL or an
external PLL on some boards).

On PS4 + Liverpool + MN864729 bridge, that assumption breaks: the bridge
expects a real DP signal driven by a PPLL, and "PPLL_INVALID" means no
PLL is programmed at all. ATOM's v6 SetPixelClock cleanly returns `r=0`
because there's nothing to do, and the GPU produces no clock.

Bridge then polls `cq_wait_set` for DP lane status that never asserts →
3-second timeout → screen dark. Same symptom as v46/v47, different
proximate cause.

---

## What was confirmed by v48

- **The whole ATOM bytecode path is healthy on Liverpool.** Two distinct
  ATOM tables (`AdjustDisplayPll` v1.3 and `SetPixelClock` v6) run cleanly
  with `r=0` when given valid input. There is no register-state
  precondition issue, no IIO accessor issue, no mutex issue. Opus / Hermes
  / GLM / DeepSeek hypotheses stay dead.
- **The v45 manual PPLL programmer is removed cleanly.** No regressions in
  boot. fb0 still registers. Bridge still cycles. Removing those two
  patches simplifies the codebase.
- **`amdgpu_pll_compute` is computing the right dividers.** The
  `ref=2 fb=118 frac=8 post=22` set produces exactly `270.0 MHz`, which is
  the DP link rate matching our floored `dp_clock`. The math is correct
  end-to-end; only the dispatch (`pll_id` picker) is wrong.

---

## v49 plan — fix the pll_id picker for Liverpool DP

Two-step in a single patch (0023):

**Step A (visibility):** Trace `amdgpu_atombios_crtc_prepare_pll` to show:
- The `pll_id` returned by `amdgpu_pll_pick_pll_id`
- The encoder type / DP-bridge-encoder-id that drove that decision
- The final `amdgpu_crtc->pll_id` value

**Step B (force fix):** If `amdgpu_crtc->pll_id == ATOM_PPLL_INVALID`
after the picker on Liverpool/Gladius, override to a valid PPLL. The
`PIXCLK1_RESYNC_CNTL = 0x1` reading from prior v45 dumps suggested PIXCLK1
routes to our active CRTC; the corresponding PPLL is `ATOM_PPLL2 = 1`
(or possibly PPLL0/PPLL1 — verify by trace first if uncertain).

If that override produces a non-`r=0` SetPixelClock or a bridge that
locks, we know the pick was the issue. If the screen still stays dark
after a valid pll_id, the next thing to check is whether the DP
transmitter / DIG encoder block needs separate programming
(`amdgpu_atombios_encoder_setup_dig` or similar).

---

## Reference paths

- Series file edit: `linux-ps4/patches/6.x-baikal/series`
  (lines for 0019/0020 commented out)
- Disabled patches (kept on disk): `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0019-amdgpu-dce-v8-liverpool-preserve-bios-pll.patch`, `…/0020-amdgpu-dce-v8-liverpool-manual-pll-program.patch`
- Active diagnostic patch: `…/0021-amdgpu-ps4-atom-display-diagnostics.patch`
- Active fix patch: `…/0022-amdgpu-ps4-floor-dp-clock-on-liverpool.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1624-v48-stock-atom-modeset.log`
- v47 result file: `linux-ps4/checkpoint/docs/research/2026-05-10-v47-dpclock-floor-result.md`
