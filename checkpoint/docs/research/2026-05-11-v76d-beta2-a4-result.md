# v76d-β-2-A4 — extend fw mirror to all 3 Sony UVD regions

**Date:** 2026-05-11 21:43
**Result:** ❌ **Regions ruled out as the gate.** Same STATUS=0x4 silent stall as A3.
**UART log:** `checkpoint/uart-logs/2026-05-11_2143-v76d-beta2-a4-all-3-regions.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0044-amdgpu-uvd-v4-2-extend-mirror-all-3-regions.patch`
**Build md5:** `eb3a67e133683d9fc977342364c90119`

## Diagnostic confirms patch took effect

```
ps4 uvd: bound fw mirror at GART virtual 0x300000000
(BO gpu_addr=0x93a000, fw_size=313912, total_regions=3178496, pages=776)
```

3 178 496 bytes = 0x308000 = 3.1 MB = regions 1+2+3 summed. 776 PTEs
populated.

## Same end state

```
STATUS=0x00000004 SOFT_RESET=0x00000000 LMI_STATUS=0x00000004
ring uvd test failed (-110)
hw_init of IP block <uvd_v4_2> failed -110
```

Zero VM faults. Zero new diagnostic data. Mapping regions 2 and 3
made no observable difference.

## What we've ruled out

| Hypothesis | Result | Ruled out by |
|---|---|---|
| Range protection trip | ❌ | v76d-α |
| GART boundary too small | ❌ | v76d-β-1 |
| PT walk fail (DEPTH=1 + flat GART) | ✅ FIXED | v76d-β-2-A |
| Null-pointer deref from zero read | ✅ FIXED | v76d-β-2-A1.5 |
| Garbage at 0x300000000 (need real fw bytes) | ✅ FIXED | v76d-β-2-A2 |
| Read-only PTE blocking writes | ✅ FIXED | v76d-β-2-A3 |
| Region 2/3 unmapped | ❌ | **v76d-β-2-A4** (this iter) |

## What remains

The VCPU is alive, executing, no memory access errors — but never
sets STATUS bit 1. Candidates not yet tested:

1. **VCPU is waiting for a register write we never do** — Sony writes
   gfx_v7-side bits like 0x1401 (we have) and 0x501=3 (need to check
   — only Sony's success path writes that).

2. **VCPU is waiting for the cache fill to complete** — Sony writes
   0x3d3d, 0x3da0, 0x3dac to release the VCPU from soft-reset in a
   specific sequence with a udelay. Maybe our timing is off.

3. **VCPU is reading at a VA we haven't mapped yet** — but it should
   fault if so, and we have zero faults. Unless the read goes through
   a different path (LMI's address-extension, direct VRAM, ICC link).

4. **A required clock/voltage isn't engaged** — Sony's
   amdgpu_asic_set_uvd_clocks(adev, 10000, 10000) sets UVD clocks via
   the SMU. We do this same call in hw_init. But it may need different
   timing or values on Liverpool.

5. **mmUVD_SCRATCH or mmUVD_RB_BASE registers** — we may be writing
   garbage to ring buffer base pointers that the VCPU then tries to
   read from.

The fact that the VCPU runs cleanly for 2 seconds (no faults, no
SOFT_RESET changes, no LMI_STATUS changes) but never makes "ready"
progress suggests it's polling for SOMETHING — a flag, an interrupt,
a register value — that we never trigger.

## Next: v76d-β-2-A5 — instrument

Read VCPU state registers EVERY 100 ms during the 2-sec poll and print
each. Watch for any value that changes — that's the VCPU showing what
it's doing. Compare with Sony's expected end-state to identify the
specific missing trigger.

Registers to sample (from Sony's get_lvp_uvd_status):
- 0x3bc6 — UVD interrupt status
- 0x3daf — UVD_STATUS (what bit set? what's changing?)
- 0x3d67 — LMI VCPU CACHE state (Sony's wait_ready polls this for 0xf)
- 0x3d42 — UVD_LMI_CTRL
- 0x3d45 — UVD_LMI_???
- 0x3e41 — UVD ring/fifo
- 0x3da0 — UVD_SOFT_RESET
- 0x3d98 — UVD_VCPU_CNTL
- 0x3d3d — UVD_RBC_RB_CNTL

Add a 5-sample dump (at t+0ms, t+500ms, t+1000ms, t+1500ms, t+2000ms)
in uvd_v4_2_start_liverpool. Should be ~30 LOC.

## Alternative: A6 — re-target CACHE_OFFSET

A6 may be unnecessary now. Looking at our current code: we already
write Sony's exact cache values (0x3d82..0x3d87) after `mc_resume`.
The cache registers point to virtual 0..0x138200 (low region) in
Sony's model. With VBASE=0 those map through to GART page 0
(dummy-bound) plus pages we never mapped (0x1000..0x138000) — yet
we see no faults from those reads.

That likely means the VCPU cache fetch doesn't go through GMC at all
— it uses a separate hardware path with direct VRAM addressing.
So A6 (re-targeting) wouldn't help; the cache mechanism is
independent of our GART work.

## Recommended: A5 (instrument)
