# v47 result — dp_clock floor in adjust_pll

**Date:** 2026-05-10
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0022-amdgpu-ps4-floor-dp-clock-on-liverpool.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `4e15e80f7a1009c4296557cbf2b09056`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1606-v47-dpclock-floor.log` (2783 lines, 197 KB)
**Result:** ❌ Display still dark, but **ATOM AdjustDisplayPll is now confirmed healthy.** Failure has moved one step downstream.

---

## What v47 was

After v46 (patch 0021) traced AdjustDisplayPll input/output and conclusively
identified `dp_clock=0` as the killer (Kimi's hypothesis), v47 floors
`dp_clock` to 270000 (PS4 internal DP link rate) inside
`amdgpu_atombios_crtc_adjust_pll` itself, since `ps4_bridge_detect` (where
v46 placed Kimi Change B) is never invoked in our boot path.

Single 14-line conditional gated on `CHIP_LIVERPOOL || CHIP_GLADIUS`:

```c
if ((adev->asic_type == CHIP_LIVERPOOL || adev->asic_type == CHIP_GLADIUS)
    && dp_clock == 0) {
    pr_info("ps4_atom: flooring dp_clock 0 -> 270000 (PS4 internal DP link)\n");
    dp_clock = 270000;
}
```

Inserted right after the existing `dp_clock = dig_connector->dp_clock` line.

---

## Marker tally

| Marker | v46 | v47 |
|---|---|---|
| `ps4_atom: flooring dp_clock 0 -> 270000` | n/a | **1 ✅** |
| AdjustDisplayPll IN | `pix=0 dp_clock=0` | **`pix=270000 dp_clock=270000`** |
| AdjustDisplayPll OUT | `r=0 freq=0 ref=0 post=0` | **`r=0 freq=270000 ref=0 post=0`** |
| `ATOM returned 0, using adjusted_mode->clock` | 1 (fallback fired) | **0 (no fallback needed)** |
| PPLL[0..3] all zero PRE+POST | 2 dumps | 2 dumps (writes still drop) |
| Bridge `cq_wait_set` between `enable: BEGIN` and `cq_exec=20` | 3.0 s | 3.0 s (unchanged) |
| `fb0: amdgpudrmfb` | 1 | 1 |

---

## Boot timing milestones

| t (s) | Event |
|---|---|
| 13.048 | First bridge `pre_enable` (force-init from patch 0007) |
| 13.089 | First `bridge_enable: BEGIN` |
| 14.433 | First `cq_exec=20` (1.3s wait — pre-modeset cycle) |
| 14.624 | First `bridge_enable: END` |
| 14.711 | **`ps4_atom: flooring dp_clock 0 -> 270000`** |
| 14.711 | **`AdjustDisplayPll v1.3 IN pix=270000 ... dp_clock=270000`** |
| 14.711 | **`AdjustDisplayPll v1.3 OUT r=0 freq=270000 ref=0 post=0`** ← real value |
| 14.711 | v45 PPLL PRE: all banks zero |
| 14.711 | v45 manual write attempt (mmDCCG_PLL_* ref/fb/post) |
| 14.711 | v45 PPLL POST: all banks **still zero** ← writes don't store, third confirmation |
| 14.712 | Second `bridge_pre_enable: BEGIN` (post-modeset cycle) |
| 14.721 | Second `bridge_enable: BEGIN` |
| **17.684** | **Second `cq_exec=20` — 3-second `cq_wait_set` hang persists** |
| 18.404 | Second `bridge_enable: END` |
| 18.686 | `[drm] fb0: amdgpudrmfb frame buffer device` |

---

## Conclusions

### What was confirmed by v47

**ATOM AdjustDisplayPll is healthy.** When given a non-zero input
(`pix=270000`, `dp_clock=270000`), ATOM returned `freq=270000` cleanly with
`r=0`. The previous v46 result (`r=0 freq=0`) was pure GIGO — feed it zero,
get zero. There was nothing wrong with the ATOM bytecode or any
register-state precondition (Opus/Hermes/GLM/DeepSeek hypotheses stay dead).

**The v28 fallback path no longer fires.** `dce_v8_0_crtc_mode_set` no
longer prints `ATOM returned 0, using adjusted_mode->clock=148500 kHz`.
`adjusted_clock` is now populated from real ATOM output.

**`ref=0 post=0` in AdjustDisplayPll output is correct for DP mode.** Those
output fields are populated only for HDMI/DVI; for DP encoder mode, divider
computation happens later in `amdgpu_pll_compute`.

### Why the screen is still dark

The mode_set path on Liverpool is structurally broken, independently of
AdjustDisplayPll's success:

1. `adjust_pll` → `freq=270000` ✅ (now works)
2. `amdgpu_atombios_crtc_set_pll` (real PLL programmer, calls ATOM
   SetPixelClock) → **patches 0019 + 0020 SKIP this for Liverpool**
3. v45 manual programmer in 0020 → writes to `mmDCCG_PLL_*` which
   **don't store** (v45 finding reaffirmed for the third time)
4. **No PLL is ever programmed.** GPU produces no clock.
5. Bridge `cq_wait_set` polls for DP lane lock indefinitely → 3-second
   timeout → screen dark.

The reasoning that originally motivated 0019/0020 (v44, v45) was: "ATOM
returned 0, so SetPixelClock probably also writes garbage; bypass ATOM and
program the PLL manually." That reasoning is invalidated by v47 — ATOM
returned 0 from `AdjustDisplayPll` because we fed it 0, not because ATOM
itself was broken.

### What v45 (0020) provably accomplishes: nothing

For the third boot in a row, the PPLL POST-program dump shows all four
banks at zero after the manual writes. Memory `ps4_6x_v45_pll_writes_drop`
is now triple-confirmed: `mmDCCG_PLL_*` is **not** the actual display PLL
on Liverpool. The patch's writes are no-ops. It is currently noise that
will mislead future analysis.

---

## v48 plan

**Disable patches 0019 and 0020 in `patches/6.x-baikal/series`**
(comment them out — the patch files stay on disk, just not applied).

This restores stock ATOM-driven mode_set:

```
adjust_pll → ATOM AdjustDisplayPll → freq=270000 (verified working in v47)
amdgpu_atombios_crtc_set_pll → ATOM SetPixelClock (v46 trace catches IN/OUT)
amdgpu_atombios_crtc_set_dtd_timing → ATOM SetCRTC_UsingDTDTiming
dce_v8_0_crtc_do_set_base → framebuffer scanout
```

The v46 trace (still active in patch 0021) will print the SetPixelClock
return value. v47's dp_clock floor stays in patch 0022. No new patch
needed; just two-line series file edit.

### Predictions

- `ps4_atom: SetPixelClock IN frev=1 crev=? crtc=0 clock=148500 pll=? ...`
  ← v46 trace finally fires
- `ps4_atom: SetPixelClock OUT r=0` if ATOM bytecode accepts the
  programming (then it writes to whatever the *real* Liverpool display PLL
  registers are, not the phantom `mmDCCG_PLL_*`)
- Bridge `cq_wait_set` 3-second hang shrinks toward <500ms
- HDMI lights up

If `SetPixelClock OUT r != 0`, the trace tells us which `frev`/`crev` was
used. We can then inspect the corresponding ATOM table or look for an
input field that needs Liverpool-specific values (most likely candidates:
`pll_id` or `encoder_id`, since the AdjustDisplayPll trace showed
`tx=0x1e enc=0`).

---

## Reference paths

- This patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0022-amdgpu-ps4-floor-dp-clock-on-liverpool.patch`
- v46 prereq (still active): `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0021-amdgpu-ps4-atom-display-diagnostics.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1606-v47-dpclock-floor.log`
- v46 result file: `linux-ps4/checkpoint/docs/research/2026-05-10-v46-atom-iio-dpclock-trace-result.md`
- Memory entries reaffirmed: `ps4_6x_v45_pll_writes_drop` (third confirmation)
