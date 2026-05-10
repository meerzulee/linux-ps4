# v59 result — skip TX DISABLE on Liverpool DP

**Date:** 2026-05-10
**Patch:** `0031-amdgpu-ps4-skip-tx-disable-preserve-firmware-dp-lock.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `e1e1b6b8c19ef427ea432158d1bbbe38`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1940-v59-skip-tx-disable.log`
**Result:** ⚠️ partial — DISABLE skip preserves f8 through DP_VIDEO_OFF/SETUP/PANEL_MODE, but TX ENABLE still destroys lock.

## Probes

```
14.975  before-INIT                    f8=0xff f9=0x1b
15.035  after-INIT                     f8=0xff f9=0x1b
15.447  before-AdjustDisplayPll        f8=0xff f9=0x1b
15.457  after-AdjustDisplayPll         f8=0xff f9=0x1b
15.467  after-SetPixelClock            f8=0xff f9=0x1b
15.477  after-DP_VIDEO_OFF             f8=0xff f9=0x1b
15.477  preserving PS4 DP TX lock; skip TX DISABLE   ← v59 fired
15.492  after-SETUP                    f8=0xff f9=0x1b
15.502  after-PANEL_MODE               f8=0xff f9=0x1b
15.512  before-TX-ENABLE               f8=0xff f9=0x1b
15.522  after-TX-ENABLE                f8=0x0f f9=0x1a   ← *** ENABLE BROKE IT ***
15.532  after-DP_VIDEO_ON              f8=0x0f f9=0x1a
```

## Conclusion

**Both halves of the TX DISABLE/ENABLE pair are destructive**, not just DISABLE. ENABLE is even more aggressive — flips `f8` straight to `0x0f` instead of DISABLE's `0x9f`. The fix needs to extend to ENABLE too.

## Why ENABLE breaks an already-enabled PHY

`setup_dig_transmitter(ENABLE)` writes ATOM v5 args including `ucDPLaneSet=0` (default voltage swing 0 / pre-emphasis 0). PS4 firmware almost certainly trained the link with non-zero per-lane swing/preemph values via DPCD-driven adaptive equalization. When ATOM bytecode rewrites `ucDPLaneSet` to default 0, the receiver immediately drops lock — even though lane count and link rate match.

## Bridge timing

- First force-init: chunk A 73ms, `0x60f8=0xff` ✅
- Second post-modeset: chunk A 606ms, `0x60f8=0x0f` ❌ (TX ENABLE killed it)
- Total bridge_enable second cycle: 3.85s

## v60 plan

Add identical Liverpool/Gladius DP gate to `setup_dig_transmitter(ENABLE)` call. Skip both halves; leave firmware-trained TX state completely untouched. DP_VIDEO_ON is the remaining unknown — its effect on intact lock will be tested in v60 for the first time.

## Reference paths

- Patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0031-amdgpu-ps4-skip-tx-disable-preserve-firmware-dp-lock.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1940-v59-skip-tx-disable.log`
- v58 result (the localizer): `linux-ps4/checkpoint/docs/research/2026-05-10-v58-step-by-step-probe-result.md`
- v60 result (the win): `linux-ps4/checkpoint/docs/research/2026-05-10-v60-skip-tx-enable-result.md`
