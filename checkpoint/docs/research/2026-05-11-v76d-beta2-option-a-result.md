# v76d-β-2 Option A — collapse VC1..VC15 to flat walk + bind dummy at 0x300000000

**Date:** 2026-05-11 20:51
**Result:** 🟡 **MAJOR PROGRESS — fault moved.** The 0x300000000 access
succeeded; firmware proceeded further into bring-up and faulted on a
DIFFERENT address with a DIFFERENT client.
**UART log:** `checkpoint/uart-logs/2026-05-11_2051-v76d-beta2-option-a.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0040-amdgpu-gmc-v7-0-liverpool-uvd-pt-fix-option-a.patch`
**Build md5:** `892c22b87108629c6009db8b6fb605df`
**Boot:** clean — SSH up, no GFX/SDMA regression observed.

## Diagnostic prints confirm both halves of the patch landed

```
[    7.796357] [drm] ps4: VC1..VC15 PAGE_TABLE_DEPTH overridden to 0 (flat walk) for UVD compatibility
[    7.805631] [drm] ps4: bound dummy page at GART virtual 0x300000000 (pa=0x1157000) for UVD fw access
```

Both registered. PT_DEPTH override took. amdgpu_gart_bind put dummy page
PA `0x1157000` at GART virtual 0x300000000.

## The fault MOVED — both address AND client changed

### Before (v76d-β-1)
```
VM_CONTEXT1_PROTECTION_FAULT_ADDR   0x00300000  (page index 0x300000 = byte 0x300000000 = 12 GB)
VM_CONTEXT1_PROTECTION_FAULT_STATUS 0x0803B002  (PROTECTIONS=0x02, bit 1 = PT walk fail)
VM fault (0x02, vmid 4, pasid 0) at page 3145728, read from 'UMC' (0x554d4300) (59)
[10 retries]
```

### After (v76d-β-2-A)
```
VM_CONTEXT1_PROTECTION_FAULT_ADDR   0x00000000  (page 0 = byte 0)
VM_CONTEXT1_PROTECTION_FAULT_STATUS 0x0803A00C  (PROTECTIONS=0x0c, bits 2+3)
VM fault (0x0c, vmid 4, pasid 0) at page 0, read from 'UVD' (0x55564400) (58)
[1 retry]
```

### What changed and why it matters

1. **FAULT_ADDR**: `0x300000` → `0x00000000`. The 0x300000000 read succeeded.
   The dummy-page binding worked. The firmware is now somewhere completely
   different in its execution.

2. **PROTECTIONS**: `0x02` → `0x0c`. Different fault type. Bits 2+3 instead
   of bit 1. We previously decoded bit 1 as "PT walk failed at invalid
   entry"; bits 2+3 likely encode "READ_PROTECTION + PDE0_PROTECTION" or
   similar — the firmware is making a real read of an unmapped VA, not
   tripping on broken PT structure.

3. **Client**: `UMC` (memory controller) → `UVD` (the UVD firmware
   *itself*). This is HUGE. Before, we couldn't tell whether the access
   was real fw-driven work or stray prefetch. Now MC_CLIENT_ID says it's
   UVD — confirming the firmware is alive, executing, and making
   meaningful reads. The bring-up sequence is making forward progress.

4. **Retry count**: 10 → 1. Hardware retried the 0x300000000 access (with
   UMC client) ~10 times. The firmware retried the page-0 access only
   once before aborting. Different behavior consistent with "fw aborts
   on bad read of expected data" vs "MC retries on missing translation".

5. **VCPU status**: same `STATUS=0x4 LMI_STATUS=0x4` "did not start after
   2s". So the firmware didn't actually run all the way to ready —
   instead it crashed or stalled after the page-0 read failed.

## Interpretation

The most likely causal chain:

1. We bound dummy page at 0x300000000. Read succeeded (returned all zeros).
2. The firmware interpreted the zeros as a null pointer / null offset.
3. It then issued a read at GPU virtual 0 (= base of our flat GART, the
   first PTE slot).
4. Nothing is bound at GART virtual 0 — gart.ptr[0] is empty.
5. PT walk fails → fault → fw abort.

This is the predicted **🟡 case** — fault moves, firmware made progress,
but our zero-fill dummy isn't enough. The firmware needs MEANINGFUL
content at 0x300000000, not just any-mapped page.

What that content is: still unknown. Sony's `gbase_map` evidently writes
something there — could be:
- A control block with real (non-zero) pointers/state
- The UVD firmware's own data section
- Sony's UVD VCPU stack (initialized to non-zero)

## Next iteration paths

### v76d-β-2-A1 — bind dummy at MULTIPLE addresses

Cheapest. Add bind at GART virtual 0 (and possibly a few more nearby
the page-0 access). Iterate based on next fault. May converge if the
firmware is just reading control pointers (which we can keep null-mapping
to dummy zeros).

```c
amdgpu_gart_bind(adev, 0x000000000ULL, 1, &fw_dummy, ...);  // VA 0
amdgpu_gart_bind(adev, 0x300000000ULL, 1, &fw_dummy, ...);  // VA 12 GB
```

**Risk**: binding at GART VA 0 might conflict with amdgpu's own GTT
allocations starting from offset 0. Need to check whether amdgpu binds
anything at offset 0 by default.

### v76d-β-2-A2 — bind UVD firmware BO at 0x300000000

Mirror the firmware contents. If the firmware is reading its own text/data,
the read returns valid instructions/data instead of zeros. The firmware BO
is in VRAM, so we'd need to either:
- Copy the firmware to a GTT BO and bind it at 0x300000000
- Use the UVD VRAM mapping somehow (more complex)

### v76d-β-2-A3 — Ghidra dive: trace what Sony's gbase_map puts at 0x300000000

This is the scientific approach. We know Sony's UVD reads work, so
Sony has bound SOMETHING at virtual 0x300000000 in vmid 4. Find out
what by tracing all `gbase_map(vmid=4, ..., 0x300000000, ...)` calls
in orbis-12.02.elf.

Cost: ~30 min Ghidra. Highest information value.

## Boot health

- ✅ SSH came up at the usual time
- ✅ No new BUG/Oops/panic compared to v76d-β-1
- ✅ amdgpu still rolls back on UVD failure (`hw_init failed -110`) —
  same as every UVD iteration since v74; not a v76d-β-2-A regression
- ✅ GFX/SDMA: not directly tested (amdgpu rolled back), but no
  intermediate panic during their probe means PT_DEPTH=0 didn't blow
  them up at init. Real test would be a boot WITHOUT UVD failure
  (e.g., temporary uvd_v4_2.c return-success-early).

## Decision

**Recommend: v76d-β-2-A1** (bind more dummy pages, iterate by fault).
Cheap, surgical, keeps building on Option A's momentum.

**OR: v76d-β-2-A3** (Ghidra trace) if we want to understand the SHAPE
of what's needed before throwing more dummy pages at it. Probably worth
30 min before committing to fault-chasing.
