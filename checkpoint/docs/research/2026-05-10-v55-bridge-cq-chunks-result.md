# v55 result — bridge cq instrumentation + MN864729 main seq chunk split

**Patch:** `0029-amdgpu-ps4-bridge-cq-instrumentation-chunk-split.patch`
**Boot log:** `checkpoint/uart-logs/2026-05-10_1823-v55-bridge-cq-chunks.log`
**Result:** Critical insight — split the monolithic 2.97s timeout into **three separate** cq_wait_* timeouts, identified `0x60f8` lane-lock as the chunk that's broken by our modeset (drops from `0xff` BIOS state to `0x0f` after Linux DPMS).

## Insight

The 2.97s timeout that haunted v46-v54 wasn't a single hang — it was the **sum of three sequential `cq_wait_*` timeouts** inside the bridge's monolithic main seq:
- chunk A: DP lane status (`0x60f8/0xff` + `0x60f9/0x01,0x1a`)
- chunk B: HDMI/update setup (`0x10f6/0x80`)
- chunk C: PLL/7204 transition (`0x7204/0x40` clear)

Chunks B and C **always** time out, both at boot and post-modeset. The bridge firmware tolerates them and continues (returns rc=20). Only chunk A actually changes between cycles:
- First cycle (BIOS state): `0x60f8=0xff`, chunk A passes fast (~30ms in v55 first cycle)
- Second cycle (post-modeset): `0x60f8=0x0f`, chunk A times out (605ms in v55 second cycle)

This proved the bridge **starts already locked** from PS4 firmware state, and our GPU-side modeset is what's destroying the lock — exactly the opposite of "the bridge needs us to train it" which was the assumption driving v53/v54.

## Implementation

Three layers added to `ps4_bridge.c`:

1. **Trace cq_wait_set / cq_wait_clear enqueue** — every wait shows `addr/mask` so we see the program before exec.
2. **cq_exec timing + reply dump** — `ktime_get_ns()` before/after `apcie_icc_cmd`. Logs `code/req_len/groups/res/reply.res1/res2/count/databuf[0..7]/elapsed_us`.
3. **Split MN864729 main seq** into three `cq_init→cq_exec` chunks at wait boundaries. Inter-chunk readbacks via `cq_read+cq_exec` of polled registers.

## Bridge timing breakdown

First force-init cycle (BIOS state):
- chunk A: 31ms (lane lock OK from BIOS)
- chunk B: 441ms (always tolerated timeout)
- chunk C: 380ms (always tolerated timeout)
- total ~1.6s

Second post-modeset cycle (with v53/v54 active, before v59/v60):
- chunk A: 605ms (lane lock destroyed by mode_set — `0x60f8=0x0f`)
- chunk B: 960ms
- chunk C: 905ms
- total ~3.0s

## Significance

v55 was the inflection point. Before it: the GPU-side hypotheses (training patterns, PLL programming, encoder setup) were all consistent with "the bridge is doing something complex internally and we need to feed it the right thing." After it: the data clearly said "the bridge is fine; you just broke its receiver." That reframed the entire investigation toward "preserve firmware-trained state" — which v58/v59/v60 then implemented.

## Reference paths

- Patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0029-amdgpu-ps4-bridge-cq-instrumentation-chunk-split.patch`
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1823-v55-bridge-cq-chunks.log`
- v58 follow-on (intra-modeset probe): `…2026-05-10-v58-step-by-step-probe-result.md`
- v60 final win: `…2026-05-10-v60-skip-tx-enable-result.md`
