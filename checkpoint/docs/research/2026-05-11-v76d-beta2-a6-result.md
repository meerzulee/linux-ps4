# v76d-β-2-A6 — drop mc_resume, fix clock-write order

**Date:** 2026-05-11 22:10
**Result:** 🟡 **Measurable VCPU behavior change — cache sync reaches Sony's pattern earlier and lasts longer — but STATUS bit 1 still doesn't fire.**
**UART log:** `checkpoint/uart-logs/2026-05-11_2210-v76d-beta2-a6-skip-mc-resume.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0046-amdgpu-uvd-v4-2-skip-mc-resume-fix-clock-order.patch`
**Build md5:** `7cd19027072fedbf3797ad3d1f80f085`

## A5 vs A6 sample table comparison

```
A5 (with mc_resume):                 A6 (without mc_resume):
  ms |  STATUS  | 0x3d67              ms |  STATUS  | 0x3d67
   0 |00000004 |0000196f               0 |00000004 |0000196f
 400 |00000004 |0000196f             400 |00000004 |0000196f
 800 |00000004 |0000196f             800 |00000004 |00003f7f  ← reaches synced earlier
1200 |00000004 |00003f7f            1200 |00000004 |00003f7f  ← sustained
1600 |00000004 |0000196f            1600 |00000004 |0000196f
```

**0x3d67 reaches Sony's synced pattern (`0x240` bits 6+9 set) at t=800
instead of t=1200, and HOLDS it for 400+ ms instead of being momentary.**

The UDEC tile-config change had a real, measurable, positive effect on
LMI cache sync behavior. But STATUS bit 1 still doesn't set — UDEC
was a real variable, just not THE gate.

## Conclusions

1. **UDEC_ADDR_CONFIG mismatch was a real bug** that misconfigured the
   UVD decode engine's view of framebuffer tiling. The fix improves
   cache sync timing measurably.

2. **STATUS bit 1 has a different gate.** The VCPU is alive, cache
   sync works better, but the microcode still doesn't decide "I'm
   ready".

3. All other registers (0x3d42, 0x3d40, 0x3d3d, 0x3d98, 0x3da0, 0x3bc6,
   0x3e41, 0x3d45) stay static across all 5 samples. No interrupt
   activity, no LMI control changes, no ring activity.

## Hypotheses left to test

### A7: Region 3 (msgq) needs "host ready" magic
Sony's UVD has a message queue at region 3 (vmid 4 / 0x300304000).
Maybe the firmware polls the first word of this queue for a non-zero
"host present" value. We currently fill it with zeros.

Test: write `0x00000001` (or a recognizable magic) to msgq offset 0
before VCPU release, see if STATUS bit 1 sets.

### A8: Try a different firmware revision
We're using `liverpool_uvd_baikal.bin` (rev 1, 314 KB). Maybe rev 0
or gladius works better for THIS Baikal silicon.

### A9: Examine what writes UVD_STATUS bit 1
Search Sony's firmware microcode (or related kernel code) for any
write to STATUS bit 1 or UVD_STATUS. May not be findable in static
binaries since the VCPU microcode is a foreign ISA.

### A10: SMU UVD power-on sequence
Sony's bring-up calls `amdgpu_asic_set_uvd_clocks(adev, 10000, 10000)`
(we do too). Maybe Liverpool needs an additional SMU command before
the VCPU can fully come up. Look for SBL/ICC writes Sony does as part
of UVD init that we don't.

## Decision

**A7 — write magic to msgq offset 0.** Cheapest non-trivial test
(~5 LOC). If the firmware was polling for a host-ready value, this
unblocks it. If not, we've eliminated another hypothesis.

If A7 doesn't help: A8 (different fw rev) is next.

A9/A10 are deeper investigations requiring more Ghidra time.
