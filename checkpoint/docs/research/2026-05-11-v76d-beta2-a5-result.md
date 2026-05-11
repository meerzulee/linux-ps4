# v76d-β-2-A5 — instrument STATUS poll

**Date:** 2026-05-11 21:57
**Result:** 🟢 **DECISIVE NEW DATA — VCPU is alive and cache-syncing, but never fires the "ready" microcode signal.**
**UART log:** `checkpoint/uart-logs/2026-05-11_2157-v76d-beta2-a5-instrument.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0045-amdgpu-uvd-v4-2-instrument-status-poll.patch`
**Build md5:** `8753f87a959e0be95ace52656dfe084c`

## The sample table

```
  ms |  STATUS  | 0x3d67  | 0x3d42  | 0x3d40  | 0x3d3d  | 0x3d98  | 0x3da0  | 0x3bc6  | 0x3e41  | 0x3d45
    0 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
  400 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
  800 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
 1200 |00000004 |00003f7f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
 1600 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
```

## Decoded findings

### 1. The VCPU IS ALIVE
- `0x3d67` (LMI VCPU cache state) **oscillates** between 0x196f and 0x3f7f
- Every 1200 ms (one transient sample captured at exactly that mark), the cache enters a more-active state with bits 8, 9, 13 additionally set
- This proves the firmware microcode IS executing — something is causing the cache to refill / sync periodically

### 2. The VCPU reaches Sony's "ready" cache state — briefly
- Sony's `uvd_vcpu_wait_ready` polls for `(0x3d67 & 0x240) == 0x240` (bits 6 + 9 both set)
- At t=1200ms, our `0x3d67 = 0x3f7f` has bits 6 AND 9 set → **matches Sony's "wait_ready" success pattern**
- So the LMI is reaching the synced state Sony expects
- But it's TRANSIENT — drops back to 0x196f (only bit 6 set) afterward

### 3. STATUS bit 1 never sets
- `0x3daf = 0x4` (only bit 2 = "VCPU init busy") throughout
- Sony's bring-up expects bit 1 to set within 2 sec
- Our VCPU never asserts it

### 4. Everything else is static
- `0x3d42` (LMI_CTRL) = 0 — LMI control unchanged
- `0x3d40` (LMI_CTRL2) = 0 — Sony writes bit 1 after success; we never reach success
- `0x3d3d` = 0x003e0030 — frozen
- `0x3d98` (VCPU_CNTL) = 0x0ff20200 — frozen
- `0x3da0` (SOFT_RESET) = 0 — fully released (good)
- `0x3bc6` (UVD interrupt status) = 0 — no IRQ events from VCPU
- `0x3e41` (UVD ring/fifo) = 0 — empty
- `0x3d45` = 0 — empty

## Interpretation

The firmware microcode is in a **steady-state loop**. It's:
- Executing (cache cycling proves this)
- Reaching the LMI-synced state intermittently (bits 6+9 at t=1200ms)
- NOT advancing to the "I'm done with init, set STATUS bit 1" code path

The "ready" assertion is a microcode-internal decision. The fw is choosing not to assert it. Two top hypotheses:

**Hypothesis A: fw is polling a memory address for a value we never set.**
The fw might be reading a "host has me" signal from region 2 (heap/IB) or region 3 (msgq) — a specific non-zero value that the host (kernel) is supposed to write before VCPU bring-up.

**Hypothesis B: fw expects a specific firmware revision check.**
At some offset into region 1, the fw might check a magic value or version field. If our memcpy starts at the wrong offset within the fw blob, the fw reads garbage at this check and refuses to proceed.

## Sony's bring-up details we can re-check

Looking back at `uvd_vcpu_start_baikal` from Ghidra:

1. **Indirect register writes via 0x3d28/0x3d29** — Sony writes subregs 0x99, 0x9a, 0x162, 0x9b. Subreg 0x9b has `& 0xffffffef` (clear bit 4) applied TWICE during bring-up. We do this; check timing.

2. **Register 0x3da9** — Sony writes a randomized value via De Bruijn `__ffs(0x1000) + __ffs(0x100) * 0x100 + 0x11010000`. We hardcoded `0x1101080c`. Maybe the randomization matters and Sony's value isn't actually constant — they regenerate per boot.

3. **Register 0x3dac = 0x10** — Sony writes this. Do we? Let me check.

4. **Register 0x3dab |= 3** — Sony does this near the end. Then we have `0x3dab |= 1` early. Sony also has `0x3dab |= 1` early. Recheck the exact ordering.

5. **mmUVD_LMI_VCPU_CACHE_VMID register at 0x3d3c** — Sony writes `ctx[+0x40] & 0xf`. We use 4 (`uint32_t k = 4`). What if the VCPU uses VMID-tagged accesses internally and the firmware was built expecting a specific VMID?

## Next iteration candidates

### A6 (cheapest first): re-read Sony's start_baikal and verify EVERY register matches

Take a fresh look at the Ghidra decompile of `uvd_vcpu_start_baikal` (FUN_c88f8610) and compare line-by-line with our `uvd_v4_2_start_liverpool`. Any divergence (missing write, wrong value, wrong order) is suspect.

This is mostly a code review. Could be done quickly without rebuild.

### A7: try a different VMID

We currently use VMID 4 (hardcoded in `uint32_t k = 4`). Maybe Baikal expects VMID 0 (kernel) or 1 (the first user vmid). Try VMID 0 — if the VCPU has internal hardware that special-cases VMID 0, that might unlock the bring-up.

### A8: write SPECIFIC magic values to regions 2/3 before bring-up

Region 3 is the message queue. Sony's userspace writes to it to communicate with the VCPU. Maybe the fw expects a "host ready" magic at region 3 offset 0 before it sets STATUS bit 1.

Try writing 0x80000000 (or similar wide-bit-set pattern) to region 3 [offset 0] and see if the fw advances.

### A9: try a different firmware revision

We have three firmware blobs (rev0, baikal, gladius). Maybe the fw we extracted has subtle differences from what runs on this exact PS4. Try rev0 or gladius instead.

## Decision

A6 first — code review of the bring-up sequence against Sony's Ghidra decompile. Free, fast. If A6 reveals divergence, fix and test. If A6 confirms our sequence matches Sony's exactly, escalate to A7 (VMID change) or A8 (region magic values).
