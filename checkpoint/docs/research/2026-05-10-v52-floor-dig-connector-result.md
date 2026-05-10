# v52 result — floor `dig_connector->dp_clock` and `dp_lane_count`

**Patch:** `0026-amdgpu-ps4-floor-dig-connector-dp-link-config.patch`
**Boot log:** `checkpoint/uart-logs/2026-05-10_1742-v52-floor-dig-connector.log`
**Result:** ✅ encoder-side sees correct values; ❌ bridge still hangs (other suspects).

v51 trace showed `dig_encoder` and `dig_tx` both received `dp_clk=0 dp_lanes=0` because v47's local-variable floor in `adjust_pll` doesn't propagate to `dig_connector` fields that downstream consumers read directly.

v52 floors the connector fields themselves (`dp_clock=270000`, `dp_lane_count=4`) inside the existing `if (connector)` block in `amdgpu_atombios_crtc_adjust_pll`. After v52:
- `dig_encoder action=0x0c/0x0f/0x10/0x0d`: now show `dp_clk=270000 dp_lanes=4` ✅
- `dig_tx action=0/1`: show `dp_clk=270000 dp_lanes=4` (with `lane_num=0 lane_set=0x00` — function params, not used by v5 ENABLE)
- Bridge `cq_wait_set` still hangs 3.0s (other steps still disturbing the link)

Next: v53 added explicit TX SETUP + SETUP_VSEMPH to test whether the missing SETUP sequence was the issue. Eventually v58 localized the actual killer to TX DISABLE/ENABLE pair.

v52 stays in the active stack — required for ENABLE to read correct `ucLaneNum`/`usSymClock` even though we now skip the call (kept for safety / completeness).
