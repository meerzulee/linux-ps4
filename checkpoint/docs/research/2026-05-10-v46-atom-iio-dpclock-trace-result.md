# v46 result — ATOM/IIO/dp_clock instrumentation bundle

**Date:** 2026-05-10
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0021-amdgpu-ps4-atom-display-diagnostics.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `4ed2988e0b390e50b917a05b18529e31`, 9 798 656 bytes)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1550-v46-atom-iio-dpclock-trace.log` (2875 lines, 203 KB)
**Result:** ❌ HDMI still dark, but **definitively localized the root cause** — `dp_clock=0` poisons ATOM input.

---

## What v46 was

After v40 (IRQ9/ACPI fix), v42 (no-skip-ATOM), v44 (PPLL diagnostic dump), v45 (manual PPLL programmer) all booted with the screen still dark, we ran five parallel multi-agent syntheses on the v42/v43 logs (`research/ideas/2026-05-10-*.md`). They split four ways on *why* `amdgpu_atom_execute_table()` returns 0 for `AdjustDisplayPll`:

- **Opus 4.7** — GPU register state is wrong when ATOM runs.
- **Hermes / GPT-5.5** — 6.x dropped `ioreg_read/write` callbacks; PS4 VBIOS may use ATOM IIO opcodes that now hit the wrong path.
- **GLM 5.1** — Same as Hermes, sharper: 6.x removed entire I/O BAR infrastructure (`rio_mem`, `cail_ioreg_*`). Restore the `rio_mem` mapping.
- **Kimi 2.6** — `dp_clock` is being zeroed *upstream* of ATOM by a failed DPCD read (lost `ddc` adapter). ATOM dutifully returns 0 when fed `usPixelClock=0`.
- **DeepSeek v4** — PPLL writes need a reset/lock sequence (self-flagged as likely wrong).

v46 bundled the **cheapest data-gathering pieces** of Opus + Hermes + GLM, plus Kimi's 2-line defensive `dp_clock` floor, into one patch designed so that **a single boot disambiguates four of five hypotheses**.

### Four instrumentation points + one defensive write (all gated on `CHIP_LIVERPOOL || CHIP_GLADIUS` where applicable)

1. `atombios_crtc.c::amdgpu_atombios_crtc_adjust_pll` v3 case — capture `r` from `amdgpu_atom_execute_table` (currently discarded), print input fields and output fields.
2. `atombios_crtc.c::amdgpu_atombios_crtc_program_pll` — capture `r` from the SetPixelClock execute call.
3. `atom.c::atom_iio_execute` ATOM_IIO_READ/WRITE — `pr_info_once` on first IIO opcode of either kind (definitively answers whether VBIOS uses indirect-I/O at all).
4. `ps4_bridge.c::ps4_bridge_detect` — defensive floor: `dp_clock = 270000`, `dp_lane_count = 4`.

DeepSeek's PPLL lock sequence was **deliberately skipped** because the existing memory entry `ps4_6x_v45_pll_writes_drop` already proved those `mmDCCG_PLL_*` registers don't store on Liverpool.

---

## Boot timing milestones

| t (s) | Event |
|---|---|
| 12.884 | `Fetched VBIOS from ROM BAR` |
| 12.890 | `ATOM BIOS: 113-Starsha2-018` (parsed cleanly) |
| 13.024 | `ps4_bridge: forcing bridge init at attach (mode=VIC 16)` (patch 0007) |
| 13.063 | `ps4_bridge_enable: BEGIN` (first cycle, BEFORE mode_set) |
| 14.426 | `MN864729 main seq cq_exec=20` (first bridge cycle, ICC OK) |
| 14.616 | `ps4_bridge_enable: END` |
| 14.710 | `ps4_bridge_get_modes` |
| 14.717 | **`ps4_atom: AdjustDisplayPll v1.3 IN pix=0 tx=0x1e enc=0 cfg=0x20 ext_tx=0x00 dp_clock=0`** |
| 14.717 | **`ps4_atom: AdjustDisplayPll v1.3 OUT r=0 freq=0 ref=0 post=0`** |
| 14.717 | `ATOM returned 0, using adjusted_mode->clock=148500 kHz` (v28 fallback fires) |
| 14.717 | v45 PRE-program PPLL state: PPLL0..3 ALL `ref=0 fb=0 post=0 cntl=0` |
| 14.717 | v45 manual write attempt — packed `ref=0x1 fb=0x000b000e post=0x8` |
| 14.717 | v45 POST-program PPLL state: PPLL0..3 STILL ALL `ref=0 fb=0 post=0 cntl=0` ← **writes do not store** |
| 14.718 | `ps4_bridge_pre_enable: BEGIN` (second cycle, AFTER mode_set) |
| 14.727 | `ps4_bridge_enable: BEGIN` (mode=VIC 16, dev=0x9923) |
| 17.696 | `MN864729 main seq cq_exec=20` (3-second wait — `cq_wait_set` polling for DP lane lock that never arrives) |
| 18.411 | `ps4_bridge_enable: END` |
| 18.695 | `[drm] fb0: amdgpudrmfb frame buffer device` (software path completes) |

**Display: dark.** Bridge command queue is healthy (cq_exec=20), but the GPU never produces a live DP signal because PLL is unprogrammed.

---

## Marker tally

| Marker | Hits | Verdict |
|---|---|---|
| `ps4_atom: AdjustDisplayPll IN/OUT` | 2 (one IN+OUT) | Trace fired as planned |
| `ps4_atom: SetPixelClock IN/OUT` | 0 | **By design** — patch 0019 skips `amdgpu_atombios_crtc_set_pll` for Liverpool, so the second ATOM call never executes |
| `amdgpu_atom_iio: first IIO_READ/WRITE` | 0 | **Hermes/GLM IIO hypothesis killed** — Starsha2-018 VBIOS does not use ATOM indirect-I/O opcodes at all |
| `ps4_bridge_detect: forcing dp_clock=270000` | 0 | **Kimi Change B placement was wrong** — `ps4_bridge_detect()` is a connector `.detect` callback that simply doesn't run in this boot path |
| `PPLL[0-3] ref=0x00000000` (v45 PRE+POST) | 2× | **Memory `ps4_6x_v45_pll_writes_drop` reaffirmed** — `mmDCCG_PLL_*` is NOT the real display PLL on Liverpool |
| `ATOM returned 0, using adjusted_mode->clock=148500` | 1 | v28 fallback as expected |
| `fb0: amdgpudrmfb frame buffer device` | 1 | Software pipeline completes |

---

## Definitive conclusions

### What was killed by this boot

| Hypothesis | Verdict |
|---|---|
| Hermes/GLM — ATOM IIO accessor / I/O BAR removal | **DEAD** — no IIO opcodes ever executed |
| Opus — GPU register state wrong when ATOM runs | **DEAD** — ATOM ran cleanly with `r=0`, no abort path triggered. The table didn't fail because of register state; it succeeded because it was given a zero input |
| DeepSeek — PPLL needs reset/lock sequence | **DEAD** — v45 confirmed for the second time that `WREG32` to `mmDCCG_PLL_*` doesn't even store. Adding a "lock sequence" to phantom registers is wasted effort |

### What was confirmed

**Kimi's hypothesis is the winner.** The chain is:

```
dig_connector->dp_clock == 0
  → in atombios_crtc.c:332 dp_clock = dig_connector->dp_clock
  → in case 3 of adjust_pll, encoder mode is DP, so:
      args.v3.sInput.usPixelClock = cpu_to_le16(dp_clock / 10) = 0
  → ATOM AdjustDisplayPll executes successfully (r=0) with usPixelClock=0
  → ulDispPllFreq=0 (GIGO)
  → v28 fallback sets adjusted_clock = mode->clock = 148500 kHz
  → v44 path skips amdgpu_atombios_crtc_set_pll on Liverpool
  → v45 hand-written WREG32 to mmDCCG_PLL_* doesn't store
  → No PLL is ever programmed
  → Bridge cq_wait_set polls for DP lane lock indefinitely
  → 3-second timeout, screen dark
```

The smoking-gun line is at log line 2625:

```
[14.717315] amdgpu: ps4_atom: AdjustDisplayPll v1.3 IN pix=0 tx=0x1e enc=0 cfg=0x20 ext_tx=0x00 dp_clock=0
[14.717324] amdgpu: ps4_atom: AdjustDisplayPll v1.3 OUT r=0 freq=0 ref=0 post=0
```

`dp_clock=0` is the input. Everything downstream is a reaction to that.

### Why Kimi Change B (the defensive write in `ps4_bridge_detect`) didn't fire

`amdgpu_ps4_dp_connector_funcs.detect` points to `ps4_bridge_detect`, but DRM's helper-detect path is not exercised during the v40+v42+v44+v45 boot sequence. Bridge is force-attached at probe (patch 0007 → `pre_enable` + `enable` + `mode_set`), then detect is bypassed entirely. Result: `dig_connector->dp_clock` stays at its zero-init value through the entire path.

The defensive write needs to live at a function that *actually runs* before `AdjustDisplayPll`. Two options:

1. **Inside `amdgpu_atombios_crtc_adjust_pll`** — single-point fix at the actual consumer, immediately after the `dp_clock = dig_connector->dp_clock` line. This is the chosen v47 approach.
2. **Inside `ps4_bridge_get_modes`** — runs at t=14.710 (before adjust_pll at 14.717), but requires accessing the same `con_priv` and is an indirect fix.

---

## Open question for the next iteration

We know `dp_clock=0` is the proximate cause of `freq=0`. After v47 floors `dp_clock=270000`, two outcomes are possible:

- **A: ATOM returns non-zero `freq` and valid `ref/post` dividers** → the v28 fallback no longer fires, real PLL programming proceeds, screen lights up (or at least bridge `cq_wait_set` shrinks from 3s to <500ms).
- **B: ATOM still returns `freq=0`** → the DP-mode AdjustDisplayPll path on Liverpool needs more than just a non-zero pixel clock input. May need correct `ucDispPllConfig`, `ucExtTransmitterID`, etc. The v46 trace already shows: `tx=0x1e enc=0 cfg=0x20 ext_tx=0x00`. If outcome B, those fields become the next investigation.

A separate concern surfaced by v46: **the v45 manual PLL programmer is provably useless** (writes don't store). It should be removed in v47 or shortly after, because it's currently noise that will mislead future analysis. Either find the real Liverpool display-PLL register addresses (per the original ATOM IIO trace plan, but now via a different mechanism since Starsha2 doesn't use IIO) or revert 0020.

---

## Reference paths

- Patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0021-amdgpu-ps4-atom-display-diagnostics.patch`
- Boot log (saved excerpt): `linux-ps4/checkpoint/uart-logs/2026-05-10_1550-v46-atom-iio-dpclock-trace.log`
- Raw rolling UART: `ps4-uart/logs/ps4_uart_20260510_133104.log` (start byte 2257710)
- Idea source files (multi-agent): `research/ideas/2026-05-10-{deepseek-ppll-lock-sequence,display-atom-trace-and-liverpool-regs,glm-iobar-restoration,hermes-atom-iio-diagnostics,kimi-dp-clock-zero}.md`
- Plan file: `~/.claude/plans/let-us-try-them-snazzy-bumblebee.md`
- Memory entries reaffirmed: `ps4_6x_v45_pll_writes_drop` (PPLL doesn't store), `display_ideas_2026_05_10` (multi-agent synthesis)

---

## v47 plan

Single-line fix in `amdgpu_atombios_crtc_adjust_pll`, gated on Liverpool/Gladius:

```c
/* PS4 internal DP→MN864729 link is hardwired at 4 lanes @ 2.7 Gbps.
 * dig_connector->dp_clock is never populated for Liverpool because the
 * detect/dpcd path doesn't run, so floor it here at the actual consumer. */
if ((adev->asic_type == CHIP_LIVERPOOL || adev->asic_type == CHIP_GLADIUS)
    && dp_clock == 0)
    dp_clock = 270000;
```

Keep the v46 instrumentation (AdjustDisplayPll IN/OUT trace) — it's now ongoing visibility for free. Drop nothing yet — the IIO trace and SetPixelClock trace are dead code on Liverpool but harmless and may prove useful on other ASICs or after other future patches.
