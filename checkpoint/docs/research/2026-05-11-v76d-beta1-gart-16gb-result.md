# v76d-β-1 — extend Liverpool GART size from 512 MB to 16 GB

**Date:** 2026-05-11 20:25
**Result:** ❌ **Identical fault** — but DIAGNOSTICALLY decisive.
**UART log:** `checkpoint/uart-logs/2026-05-11_2025-v76d-beta1-gart-16gb.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0039-amdgpu-gmc-v7-0-liverpool-gart-size-16gb.patch`
**Build md5:** `287ef5c4fe9f258bfbff10a31cb420ee`
**Boot:** clean — SSH up, no panic-on-boot regressions.

## Confirmed: patch took effect

```
amdgpu 0000:00:01.0: amdgpu: GART: 16384M 0x0000000000000000 - 0x00000003FFFFFFFF
[drm] GART: num cpu pages 4194304, num gpu pages 4194304
```

GART range 0..0x3FFFFFFFF (16 GB - 1 byte), 4 194 304 PTE slots. Was 512 MB
in v76d-α. So our patch absolutely landed.

## Counts vs. v76d-α

| Signal | v76d-α | v76d-β-1 |
|---|---|---|
| GART size | 512 M | **16 384 M** |
| VC[4]_END_ADDR (from 0038) | 32 GB - 1 | 32 GB - 1 |
| `VM fault ... vmid 4, page 3145728` | 10 | **10** |
| `STATUS=0x0803B002` | yes | **yes (identical)** |
| `ADDR=0x00300000` | yes | **yes (identical)** |
| `Liverpool VCPU did not start` | yes | yes |
| `hw_init of IP block <uvd_v4_2> failed -110` | yes | yes |
| Boot completes to SSH | yes | yes |

Byte-identical fault status. Two big variables changed (GART size 32x larger,
VC4 range still 32 GB) and **nothing moved.** The negative is decisive.

## Decoding PROTECTIONS = 0x02

`VM_CONTEXT1_PROTECTION_FAULT_STATUS = 0x0803B002`.

`gmc_7_0_sh_mask.h` confirms `PROTECTIONS_MASK = 0xff, SHIFT = 0`, so
PROTECTIONS = 0x02. That's **bit 1 set**.

In CIK GMC, bit 1 of PROTECTIONS is the **PT walk failure flag**: the GMC's
page-table walker hit an invalid entry on the way to translating the VA.
It is NOT "range protection" (that would be bit 0 or bit 4 depending on
chip). Our v76d-α extending VC4's END_ADDR was a stab at range; the
unchanging fault under both bigger range AND bigger GART confirms it was
never a range issue.

## What's actually failing — the PT walk

VC4's `mmVM_CONTEXT1_CNTL` (per upstream gmc_v7_0_gart_enable line 707-712)
sets `PAGE_TABLE_DEPTH = 1`, meaning **2-level PD/PT walk** for VC1..VC15.
But upstream programs the same `table_addr` (= GART PT base) for all
VMIDs, including the flat-PT VC0.

For VC4 walking VA 0x300000000 = page 0x300000:
- PD_idx = VA >> 21 = 0x1800
- GMC reads PD entry at `table_addr + 0x1800 * 8 = table_addr + 0xC000`
- That memory is byte offset 0xC000 into the flat GART, which corresponds
  to GART page index 0x1800 (covering GPU virtual byte 0x1800000 = 24 MB)
- amdgpu hasn't bound anything at GART virtual page 0x1800, so the entry
  is zero → PD entry invalid → **bit 1 = PT walk failure**

This is structurally how upstream's "Liverpool" branch of gmc_v7_0 reads
the GART — and it's broken for UVD bring-up. The shared flat GART can't
serve as a 2-level PD for VC1..VC15 because the byte content doesn't
follow the PD-entry semantics.

## Three options for v76d-β-2

### Option A — collapse VC4 to PAGE_TABLE_DEPTH=0 (RECOMMENDED)

Override `PAGE_TABLE_DEPTH` to 0 in VC1's CNTL for Liverpool/Gladius, so
VC1..VC15 walk the flat GART exactly like VC0. Then bind a BO at GART
virtual offset 0x300000000 — the PTE there becomes valid → fw read
succeeds.

```c
// In gmc_v7_0_gart_enable, after the existing CNTL setup:
if (adev->asic_type == CHIP_LIVERPOOL || adev->asic_type == CHIP_GLADIUS) {
    tmp = RREG32(mmVM_CONTEXT1_CNTL);
    tmp = REG_SET_FIELD(tmp, VM_CONTEXT1_CNTL, PAGE_TABLE_DEPTH, 0);
    WREG32(mmVM_CONTEXT1_CNTL, tmp);
}
```

Plus: in `uvd_v4_2.c` Liverpool branch, after firmware is loaded, bind
the fw BO at GART virtual page 0x300000 via `amdgpu_gart_bind` (or write
PTEs manually if the API is awkward).

Cost: ~10 lines of code. Reverses upstream's deliberate VC1+ 2-level
config — may regress GFX/SDMA if they relied on it. Worth checking the
git blame for line 709 to understand why DEPTH=1 was set.

### Option B — pre-populate PD entries at table_addr + 0xC000

Keep PAGE_TABLE_DEPTH=1. Write valid PD entries at the PD slot
corresponding to VA 0x300000000 (= 0x1800), pointing to a real 4 KB PT
page. Populate that PT page with PTEs pointing to the firmware physical
pages.

Cost: ~30 lines. Closer to Sony's per-vmid PD model. Doesn't disturb GFX.

### Option C — bind UVD fw BO at GART offset 0x300000000 directly

Even simpler than A: don't touch CNTL. Just call `amdgpu_gart_bind`
or a manual GART entry write to populate `table_addr[0x300000..0x300400]`
with real PTEs pointing to the firmware buffer.

This relies on the assumption that VC4's 2-level walk will succeed when
the "PD entry" (= GART PTE at index 0x1800) is valid. The fault we're
seeing is that PD entry being zero. If we set GART[0x1800] = valid PTE
pointing to a real page, the GMC's 2-level walker will:
1. Read PD entry at table_addr + 0x1800 * 8 — now valid
2. Use that "PT page" address to look up the actual PTE
3. The "PT page" content is whatever we put at the physical address that
   PD entry references → if we make that content match what UVD needs
   (PTEs pointing to firmware), the walk succeeds

Cost: ~5 lines if `amdgpu_gart_bind` accepts arbitrary GART offsets.

**Recommended order**: try Option A first (cleanest, fewest variables).
If GFX/SDMA regress, fall back to Option B or C.

## v76d-β-1 patch impact assessment

- Build: clean, no compile errors
- Boot: SSH up, kernel running stably
- GFX/userspace: amdgpu rolls back on UVD failure (`amdgpu_driver_unload_kms`
  fires after `hw_init failed`). This was happening in v76b too — not a
  v76d-β-1 regression. HDMI from earlier framebuffer takeover (simplefb)
  still works.
- Memory cost of bigger GART: 4M PTEs × 8 B = 32 MB GTT memory. Allocated
  during gart_init. No OOM signs in dmesg.
