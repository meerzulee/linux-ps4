# v60 result — HDMI WORKING 🏆

**Date:** 2026-05-10
**Patches:** `0031-amdgpu-ps4-skip-tx-disable-preserve-firmware-dp-lock.patch` (v59) + `0032-amdgpu-ps4-skip-tx-enable-too.patch` (v60)
**bzImage:** `output/6.x-baikal/bzImage` (md5 `c546c149ce26af30ea26efd030a3c3f4`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1955-v60-skip-tx-enable-too.log` (3351 lines, 245 KB)
**Result:** ✅ **HDMI display lights up.** initramfs renders text on the screen for the first time on PS4 6.x.

---

## The fix in one sentence

**Do not call `setup_dig_transmitter(DISABLE)` and `setup_dig_transmitter(ENABLE)` on PS4 Liverpool/Gladius DP encoders during modeset.** Leave the firmware-trained UNIPHY PHY completely untouched. DIG (digital encoder), CRTC, PPLL, framebuffer, and bridge programming all run normally.

---

## Lane lock preserved end-to-end

```
15.029  before-dig_tx-action=7 (INIT)              f8=0xff f9=0x1b
15.089  after-dig_tx-action=7  (INIT)              f8=0xff f9=0x1b
15.500  before-AdjustDisplayPll                    f8=0xff f9=0x1b
15.510  after-AdjustDisplayPll                     f8=0xff f9=0x1b
15.521  after-SetPixelClock                        f8=0xff f9=0x1b
15.530  after-dig_encoder-action=0x0c (DP_VIDEO_OFF) f8=0xff f9=0x1b
15.530  preserving PS4 DP TX lock; skip TX DISABLE   ← v59 fired
15.545  after-dig_encoder-action=0x0f (SETUP)      f8=0xff f9=0x1b
15.555  after-dig_encoder-action=0x10 (PANEL_MODE) f8=0xff f9=0x1b
15.555  preserving PS4 DP TX lock; skip TX ENABLE    ← v60 fired
15.565  after-dig_encoder-action=0x0d (DP_VIDEO_ON) f8=0xff f9=0x1b
```

Every probe shows `f8=0xff f9=0x1b`. The firmware-trained DP receiver lock survives the entire modeset. DP_VIDEO_ON was the last open question — it operates on the DIG block (digital framing), not the analog UNIPHY frontend, so the trained PHY state is untouched.

## Bridge timing — 3-second hang gone

| Cycle | v55-v59 | **v60** |
|---|---|---|
| Force-init (first) | ~1.6s baseline | 1.84s baseline |
| **Post-modeset (second)** | **3.0s ❌** chunk A timeout, `0x60f8=0x0f` | **1.66s ✅** chunk A passes, `0x60f8=0xff` |
| Bridge `0x60f8` readback after chunk A (second cycle) | `0x0f` (broken) | **`0xff` (intact)** |

The 2.97-second timeout that haunted v46 through v59 came specifically from chunk A polling `0x60f8 == 0xff` and failing because we'd broken it. With `f8=0xff` actually intact, chunk A passes (~520ms) and chunks B/C still take their tolerated baselines (~450ms each), but the bridge **completes successfully** and HDMI scanout begins.

## Visual proof

User's photo (`Downloads/IMG_20260510_195300931.jpg`) shows screen rendering:

```
>> better-initramfs v0.9.1, Linux kernel 6.15.4-Baikal_TESTING_crashniels-dirty.
>> Mounting /proc...
>> Mounting /sys...
>> Create all the symlinks to /bin/busybox...
>> Mounting /dev (devtmpfs)...
```

initramfs is active. The screen is on. The boot continues normally past the bridge enable.

---

## Why this works (the model)

PS4 firmware leaves the GPU's UNIPHYA DP transmitter **already trained and locked** to the MN864729 bridge at the moment Linux starts. Sony has knowledge of the exact electrical configuration (per-lane voltage swing, pre-emphasis, link-rate, secondary parameters) that's not exposed in standard ATOM defaults — and not derivable from VBIOS object info.

amdgpu's normal modeset flow on a hot-plug PC DP monitor would:
1. Call `setup_dig_transmitter(DISABLE)` to power down the PHY
2. Reprogram CRTC/PLL/encoder
3. Call `setup_dig_transmitter(ENABLE)` to power up with new settings
4. Run `dp_link_train` — DPCD-driven adaptive equalization to retrain swing/preemph per lane

That works on a normal monitor because steps 4 retrains. On PS4, the bridge **does not respond to standard DPCD link training** (patch 0006 made `dp_link_train` early-return because the kernel's clock-recovery loop times out 5x). Once step 1 tears down the trained PHY, there's no working trainer to bring it back.

`setup_dig_transmitter(ENABLE)` writes ATOM v5 args:
- `ucPhyId = UNIPHYA`
- `ucLaneNum = 4` (from v52 `dig_connector` floor)
- `usSymClock = 27000` (from v47 `dp_clock` floor, 270 MHz)
- **`ucDPLaneSet = 0`** (default voltage swing 0, pre-emphasis 0)

The `ucDPLaneSet = 0` was the kicker. PS4 firmware almost certainly trained the link with non-zero swing/preemph values per lane (DPCD-driven adaptive equalization). When ATOM bytecode rewrites `ucDPLaneSet` to default 0, the receiver immediately drops lock — even though lane count and link rate match. That's why the v53 SETUP_VSEMPH attempt didn't help: `lane_set=0` was wrong too.

The fix: never call those functions. The firmware-trained PHY remains powered, locked, and electrically configured throughout the modeset.

---

## What's NOT skipped (and why each is safe)

| Function | Why safe |
|---|---|
| `AdjustDisplayPll` | ATOM call, no PHY writes (queries clock; v58 confirmed f8=0xff after) |
| `SetPixelClock` | Programs PPLL2 only; doesn't touch UNIPHY PHY (v58 confirmed) |
| `DP_VIDEO_OFF` (DIG action 0x0c) | Stops video stream framer in DIG block; doesn't touch analog (v58 confirmed) |
| `dp_set_rx_power_state(D3)` | Bridge ignores DPCD anyway (v58: pre-DISABLE probe still 0xff) |
| `setup_dig_encoder(SETUP/PANEL_MODE/DP_VIDEO_ON)` (DIG actions 0x0f/0x10/0x0d) | All DIG-block operations: encode mode, lane mapping, video framer (v58/v59/v60 confirmed) |
| `INIT` (TX action 7) | Power-up; no-op on already-powered PHY (v58 confirmed pre/post = 0xff) |
| `link_train` | early-return for Liverpool (patch 0006) |

## What IS skipped (and what each was breaking)

| Function | Killer evidence |
|---|---|
| `setup_dig_transmitter(DISABLE)` (action=0) | v58: `f8: 0xff → 0x9f` exactly at this call |
| `setup_dig_transmitter(ENABLE)` (action=1) | v59 (with DISABLE skipped): `f8: 0xff → 0x0f` exactly at this call |

---

## The patch series — final state

**Active GPU patches for Liverpool DP HDMI working:**

- v40 / `0100-x86-platform/0002` — IRQ 9 ACPI desc pre-allocation (root-cause for ATOM mutex availability)
- `0001-0006` — base bridge driver, encoder/connector wiring, force MSI, skip kernel DP link train
- v21 / `0007` — force-init bridge at attach time (legacy DRM helper compat)
- v22-v32 — bridge mode_set / VIC defaults / EDID / 1080p forcing (incremental polish)
- v33 / `0017` — DISABLED (replaced by v44)
- v44 / `0019` — DISABLED post-v48 (PPLL bypass was wrong path)
- v45 / `0020` — DISABLED post-v48 (manual PPLL writes don't store)
- **v47 / `0022`** — Floor `dp_clock = 270000` in `amdgpu_atombios_crtc_adjust_pll`
- **v49 / `0023`** — Clobber `adev->clock.dp_extclk = 0` for Liverpool (forces picker to pick a real PPLL)
- **v52 / `0026`** — Floor `dig_connector->dp_clock=270000, dp_lane_count=4`
- **v59 / `0031`** — Skip `setup_dig_transmitter(DISABLE)` for Liverpool DP
- **v60 / `0032`** — Skip `setup_dig_transmitter(ENABLE)` for Liverpool DP
- v53 / `0027` — DISABLED post-v59 (TX SETUP/VSEMPH proven to also disturb)
- v54 / `0028` — DISABLED post-v56 (source-only training pulse innocent but unnecessary)

**Active diagnostic patches (kept for future regressions):**
- v46 / `0021` — ATOM call ret/in/out trace (AdjustDisplayPll, SetPixelClock)
- v50 / `0024` — generic ATOM master-table tracer
- v51 / `0025` — DIG encoder/transmitter args + PIXCLK_RESYNC trace
- v55 / `0029` — bridge cq trace + MN864729 main seq chunk split
- v58 / `0030` — step-by-step DP lane-status probe (`ps4_bridge_probe_lane_status`)

---

## Bisection narrative across 16 iterations (v45 → v60)

| v# | What | Result |
|---|---|---|
| v45 | Manual PPLL writes to mmDCCG_PLL_* | writes don't store; abandoned |
| v46 | Trace ATOM call return values + IIO opcode tracing | killed Hermes/GLM IIO hypothesis (no IIO use); revealed `dp_clock=0` going into ATOM |
| v47 | Floor local `dp_clock=270000` in adjust_pll | ATOM AdjustDisplayPll returns real `freq=270000` ✅; bridge still hangs |
| v48 | Disable v44/v45 (skip-ATOM-PLL stack) | ATOM SetPixelClock now runs but `pll=255` (INVALID) |
| v49 | Clobber `dp_extclk=0` so picker selects PPLL2 | SetPixelClock now sees `pll=1`, runs 16× longer (real PLL programming); bridge still hangs |
| v50 | Generic ATOM table tracer | full modeset table sequence captured; all ret=0; killer not in ATOM bytecode |
| v51 | Trace DIG/TX args + PIXCLK_RESYNC | `dp_clk=0 dp_lanes=0` reaching DIG/TX (connector field never populated) |
| v52 | Floor `dig_connector->dp_clock=270000, dp_lane_count=4` | DIG/TX now see correct args; bridge still hangs |
| v53 | Insert TX SETUP + SETUP_VSEMPH before ENABLE | doesn't help; final args coherent (UNIPHYA, 4lane, 270MHz, etc.) |
| v54 | Source-only DP training pulse (TPS1/TPS2) | doesn't help |
| v55 | Bridge cq instrumentation + chunk split | revealed the 2.97s timeout is sum of B+C tolerated baselines + chunk A timeout; chunk A is `0x60f8 != 0xff` |
| v56 | Disable v54 (bisect) | falsifies v54 as killer |
| v57 | Disable v53 (bisect) | falsifies v53 as killer; chunk A still broken |
| v58 | Step-by-step `ps4_bridge_probe_lane_status` across modeset | **localizes killer to TX DISABLE: `f8 0xff→0x9f` exactly** |
| v59 | Skip TX DISABLE | preserves f8 through DP_VIDEO_OFF/SETUP/PANEL_MODE; TX ENABLE still flips f8→0x0f |
| **v60** | **Also skip TX ENABLE** | **f8 stays 0xff end-to-end. Bridge passes. HDMI lights.** ✅ |

---

## Notes for follow-up

- The diagnostic patches (0021, 0024, 0025, 0029, 0030) are still active. They're verbose. Once the fix is validated across reboots and varied conditions, consider: (a) gating them behind a Kconfig or module param, (b) removing the verbose calls, or (c) keeping the lightweight ones (just the AdjustDisplayPll/SetPixelClock IN/OUT trace) and dropping the heavy probe calls.
- The disabled patches (0019, 0020, 0027, 0028) can stay disabled in the series file or be removed entirely. They represent dead-end approaches but the patch files themselves document the bisect history.
- Mode changes (different resolutions): untested. The current fix preserves whatever the firmware programmed (likely 1080p60). A user-driven mode change would need either (a) the firmware to accept retraining on the same UNIPHY, or (b) a different approach for non-firmware modes.
- DPMS_OFF (suspend / blank): with both DISABLE and ENABLE skipped, the encoder never actually powers down on screen-off. Power consumption may be slightly higher.

---

## Reference paths

- This patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0032-amdgpu-ps4-skip-tx-enable-too.patch`
- Companion patch: `…/0031-amdgpu-ps4-skip-tx-disable-preserve-firmware-dp-lock.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1955-v60-skip-tx-enable-too.log`
- Visual proof: `~/Downloads/IMG_20260510_195300931.jpg`
- v59 result: `linux-ps4/checkpoint/docs/research/2026-05-10-v59-skip-tx-disable-result.md`
- v58 result (the localizer): `linux-ps4/checkpoint/docs/research/2026-05-10-v58-step-by-step-probe-result.md`
- Multi-agent ideas (origin of the systematic approach): `research/ideas/2026-05-10-*.md`
