# v49 result — clobber dp_extclk so picker selects a real PPLL

**Date:** 2026-05-10
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0023-amdgpu-ps4-clobber-dp-extclk-pick-real-ppll.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `16ad83bd49da7aaf99f5f4291ce4149b`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1639-v49-clobber-dp-extclk.log` (2768 lines, 194 KB)
**Result:** ❌ Display still dark, but **picker is fixed and ATOM is now doing real PLL programming work** (16× longer execute time). The failure has moved one more layer down — the bridge still sees no DP signal.

---

## What v49 was

After v48 disabled the v44/v45 PPLL workaround patches and restored stock
ATOM-driven mode_set, the v46 trace caught the next blocker:

```
SetPixelClock IN frev=1 crev=6 crtc=0 clock=148500 pll=255 ref=2 fb=118 ...
SetPixelClock OUT r=0
```

`pll=255` = `ATOM_PPLL_INVALID`. ATOM v6 SetPixelClock returns `r=0`
cleanly when `ucPpll=0xFF` because there's nothing to program. The picker
`dce_v8_0_pick_pll` was returning INVALID for DP encoders because of an
early return at `dce_v8_0.c:2174-2177`:

```c
if (ENCODER_MODE_IS_DP(...)) {
    if (adev->clock.dp_extclk)
        return ATOM_PPLL_INVALID;   // <-- triggered
```

`adev->clock.dp_extclk` is read from VBIOS firmware_info_21
(`usUniphyDPModeExtClkFreq`) at `amdgpu_atombios.c:707`. Sony's Starsha2
VBIOS sets it non-zero, advertising "external DP ref clock present" —
which is wrong on PS4 (no external clock IC routed to Liverpool's
UNIPHY).

v49 (patch 0023) clobbers `adev->clock.dp_extclk = 0` for
Liverpool/Gladius right after the VBIOS read, plus two visibility prints
in `amdgpu_atombios_get_clock_info` and `dce_v8_0_pick_pll`.

---

## Marker tally

| Marker | v48 | v49 |
|---|---|---|
| `VBIOS dp_extclk=...` | n/a | **`10000`** (Starsha2 advertises 10 MHz external ref) ✅ confirmation |
| `dce_v8_0_pick_pll enc_mode=... dp_extclk=... asic=...` | n/a | **`enc_mode=0 dp_extclk=0 asic=9`** (clobber active) ✅ |
| `SetPixelClock IN ... pll=...` | `pll=255` | **`pll=1` (ATOM_PPLL2)** ✅ |
| **SetPixelClock execute time (IN→OUT)** | **22 µs** (no-op) | **355 µs (16× longer)** ✅ real PLL work |
| `SetPixelClock OUT r=` | `0` (no-op success) | `0` (real success) |
| `flooring dp_clock 0 -> 270000` | 1 | 1 |
| `AdjustDisplayPll v1.3 OUT r=0 freq=270000` | 1 | 1 |
| Bridge `cq_wait_set` (`enable BEGIN`→`cq_exec=20`) | 3.0 s | **3.0 s (unchanged)** |
| Screen | dark | dark |

---

## Boot timing milestones

| t (s) | Event |
|---|---|
| 12.909 | `ps4_atom: VBIOS dp_extclk=10000 (PS4 forces 0 on Liverpool/Gladius)` |
| 13.039 | First `bridge_pre_enable: BEGIN` (force-init from 0007) |
| 13.092 | First `bridge_enable: BEGIN` |
| 14.419 | First `cq_exec=20` (1.3 s wait — pre-modeset cycle) |
| 14.614 | First `bridge_enable: END` |
| 14.708 | `ps4_bridge_get_modes` |
| 14.715 | **`flooring dp_clock 0 -> 270000`** (v47) |
| 14.715 | **`AdjustDisplayPll v1.3 OUT r=0 freq=270000`** (v47) |
| 14.715 | **`dce_v8_0_pick_pll enc_mode=0 dp_extclk=0 asic=9`** (v49 trace) |
| 14.7148 | **`SetPixelClock IN ... pll=1 ref=2 fb=118 frac=8 post=22 ...`** (v49) |
| 14.7152 | **`SetPixelClock OUT r=0`** (v49 — 355 µs after IN) |
| 14.716 | Second `bridge_pre_enable: BEGIN` (post-modeset cycle) |
| 14.726 | Second `bridge_enable: BEGIN` |
| **17.700** | **Second `cq_exec=20`** — 3-s `cq_wait_set` hang persists |
| 18.415 | Second `bridge_enable: END` |
| 18.616 | `[drm] fb0: amdgpudrmfb frame buffer device` |

---

## What v49 proved

**The hypothesis was 100% correct.** VBIOS `dp_extclk=10000` is the value
Sony's Starsha2 advertises. The clobber to 0 took effect immediately:
- Picker enters with `dp_extclk=0` and falls through.
- `amdgpu_pll_get_shared_dp_ppll` returns INVALID (no other DP CRTC), so
  it falls into the CIK allocator at `dce_v8_0.c:2202`.
- That returns `ATOM_PPLL2 = 1`, which is what reaches ATOM
  SetPixelClock.

**ATOM SetPixelClock is now doing real work.** The execute time jumped
from 22 µs (v48 no-op when ucPpll=255) to **355 µs** in v49 — a 16×
increase. That's the cleanest signal possible that ATOM bytecode is now
actually writing PLL programming registers (whatever those are on the
real Liverpool hardware — *not* the phantom `mmDCCG_PLL_*` from the v45
patch). The whole "PLL writes don't store" story from `ps4_6x_v45_pll_writes_drop`
memory was about the *wrong* register addresses; ATOM knows the right
ones.

**But the bridge cq_wait_set still hangs 3 seconds.** Same exact symptom
as v46/v47/v48 — MN864729 polls for DP lane lock and times out. PLL is
programmed; the bridge still sees no DP signal arriving from the GPU.

---

## Where the failure lives now

ATOM SetPixelClock returned `r=0` after 355 µs of real work. The next
things that need to happen for a working DP signal between SetPixelClock
and the bridge's second `cq_wait_set`:

1. **DIG encoder setup** — `amdgpu_atombios_encoder_setup_dig_encoder`
   calls ATOM `DIGxEncoderControl` to set up encoder mode (DP), color
   depth, pixel rate.
2. **DP transmitter setup** — `amdgpu_atombios_encoder_setup_dig_transmitter`
   calls ATOM `UNIPHYTransmitterControl` with action `ENABLE` (turn on
   PHY) then `DP_VIDEO_ON` (start the video stream after link train).
3. **EnableCRTC** — `amdgpu_atombios_crtc_enable` (ATOM `EnableCRTC`)
   from DPMS_ON.
4. **BlankCRTC(disable)** — unblanks the CRTC.

Patch 0006 already skips `amdgpu_atombios_dp_link_train` for Liverpool
because the kernel's clock-recovery loop times out on the fake-DP
MN864729 link. So link-training is bypassed, but the steps before/after
it (transmitter setup + DPMS) still need to run.

The 750 µs gap between `SetPixelClock OUT` (14.715161) and
`bridge_pre_enable BEGIN` (14.715926) suggests the DRM helper sequence
(mode_set → commit → DPMS_ON → encoder_dpms) is happening fast — but the
v46 trace only catches `AdjustDisplayPll` and `SetPixelClock`. We have
**zero visibility** into whether DIG / DP TX / EnableCRTC / BlankCRTC
tables run successfully (or run at all).

---

## v50 plan — generic ATOM table tracer

Instead of adding individual print sites for each table, add **one**
generic trace inside `amdgpu_atom_execute_table()` that prints every
table index + return value. This gives complete visibility into what
ATOM tables fire (and in what order, with what return codes) during the
entire modeset sequence. Plus a second hook in the `atom_op_calltable`
opcode handler so we also see sub-table calls invoked from within ATOM
bytecode.

After the next boot, we'll have a complete ATOM-table call trace from
ASIC_Init through DPMS_ON. The first table that fails (or the table that
should run but doesn't) becomes the new investigation target.

---

## Reference paths

- This patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0023-amdgpu-ps4-clobber-dp-extclk-pick-real-ppll.patch`
- Active v46 trace: `…/0021-amdgpu-ps4-atom-display-diagnostics.patch`
- Active v47 floor: `…/0022-amdgpu-ps4-floor-dp-clock-on-liverpool.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1639-v49-clobber-dp-extclk.log`
- v48 result: `linux-ps4/checkpoint/docs/research/2026-05-10-v48-stock-atom-modeset-result.md`
