# v54 result — source-only DP training pulse

**Patch:** `0028-amdgpu-ps4-source-only-dp-training-pulse.patch` (later DISABLED in v56)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1810-v54-source-only-dp-train.log`
**Result:** ❌ Markers fire, training pattern emitted, but bridge `cq_wait_set` still hangs 3.0s. v54 falsified post-mortem in v56.

Replaced patch 0006's bare `return;` for Liverpool in `amdgpu_atombios_dp_link_train` with a helper that emits the canonical TPS sequence (`LINK_TRAINING_START → PATTERN1 → PATTERN2 → COMPLETE`) without DPCD reads. Each phase ~5ms `mdelay` so bridge can observe each pattern.

Trace confirms emission:
```
15.143  source-only DP training pulse START
15.143  dig_encoder action=0x08 (LINK_TRAINING_START)
15.148  dig_encoder action=0x09 (PATTERN1)
15.153  dig_encoder action=0x0a (PATTERN2)
15.158  dig_encoder action=0x0b (COMPLETE)
15.159  source-only DP training pulse COMPLETE
```

Bridge timing unchanged (2.97s in chunk A second cycle).

The "consistent 2.97s timeout" across v46-v54 turned out to be sum of three separate cq_wait_* timeouts inside the monolithic main seq (v55 chunk split revealed). v54's training pulse premise — that the bridge needed source-side TPS to lock — was wrong. The bridge starts already locked from PS4 firmware; our TX DISABLE/ENABLE was destroying that lock.

v56 disabled patch 0028 to bisect. Lock still broken in v56 → v54 confirmed innocent.

Patch file kept on disk for reference but commented out in series file.
