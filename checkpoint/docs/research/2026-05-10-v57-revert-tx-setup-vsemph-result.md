# v57 result — bisect: disable v53 TX SETUP/SETUP_VSEMPH too

**Series edit:** comment out `0027-amdgpu-ps4-tx-setup-vsemph-before-enable.patch` (also keep 0028 disabled)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1853-v57-revert-tx-setup-vsemph.log`
**Result:** v53 ALSO INNOCENT — chunk A second cycle still shows `0x60f8=0x0f`, ~604ms elapsed.

Stripped DPMS_ON path back to minimal stock amdgpu DP flow:
- DIG SETUP / PANEL_MODE
- TX DISABLE
- TX ENABLE
- dp_link_train (bare return for Liverpool)
- DP_VIDEO_ON

Even with neither v53 (extra SETUP/SETUP_VSEMPH) nor v54 (TPS pulse) active, the bridge still hangs. The killer is in the minimal stock path itself.

Hermes' updated suspect ranking after v57:
- TX DISABLE: ~35%
- TX ENABLE: ~25%
- SetPixelClock/PPLL: ~25%
- DP_VIDEO_OFF: ~10%
- DIG SETUP/PANEL_MODE: ~5%

Decision: instead of more blind reverts, instrument step-by-step in v58. That patch added `ps4_bridge_probe_lane_status(tag)` calls at every modeset step to localize the exact step that flips `0x60f8` from `0xff` to `0x0f`.

bzImage md5 `03e0dc03989665e04bbc9a0e99353064`.
