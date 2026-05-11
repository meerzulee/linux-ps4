# v76d-α — extend Liverpool/Gladius vmid 1..15 VA range to 32 GB

**Date:** 2026-05-11 20:08
**Result:** ❌ **Identical fault** — range-protection ruled out as the gate.
**UART log:** `checkpoint/uart-logs/2026-05-11_2008-v76d-extend-vmid-range.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0038-amdgpu-gmc-v7-0-liverpool-extend-vmid-va-range.patch`
**Build md5:** `ae0628a43a31a9db59a8cebbb1f3e77e`
**Boot:** clean — SSH came up at the usual time, no regressions.

## Counts vs. v76b (prior negative)

| Signal | v76b | v76d-α |
|---|---|---|
| Linux version banner | 1 | 1 |
| amdgpu probe complete | yes | yes |
| `VM fault ... vmid 4, page 3145728` | 10 | **10** |
| `STATUS=0x00000004 LMI_STATUS=0x00000004` after 2 s | yes | **yes** |
| `Liverpool VCPU did not start` | yes | **yes** |
| `set_powergating_state of IP block <uvd_v4_2> failed -110` | yes | yes |
| `ring uvd test failed (-110)` | yes | yes |
| `hw_init of IP block <uvd_v4_2> failed -110` | yes | yes |
| Boot completes to SSH | yes | yes |

Identical numerics. Identical fault address. Identical VCPU timeout. Even the
retry-count of the IH (10) is the same.

## What this rules out

Extending `mmVM_CONTEXT[1..15]_PAGE_TABLE_END_ADDR` from `max_pfn - 1`
(≈ 8 GB) to 32 GB - 1 did NOT change anything. So the fault at GPU virtual
0x300000000 is **NOT a range-protection trip.** The address fell inside
our new VC4 range yet still faulted.

Therefore the fault is the other kind of GMC failure: **a real "no PTE
present" miss on the PT walk.** GMC walks the shared GART page table at
the index corresponding to VA 0x300000000 (= page index 0x300000 = entry
3145728), finds no valid PTE (because the GART only covers 0..0x1FFFFFFF
= 512 MB), and raises VM_L2_PROTECTION_FAULT.

The on-PS4 GART config (confirmed via `dmesg | grep gart`):

```
amdgpu: VRAM: 1024M  0x0F00000000 - 0x0F3FFFFFFF
amdgpu: GART: 512M   0x00000000   - 0x1FFFFFFF
amdgpu: 3459M of GTT memory ready
```

GART spans 0..512 MB in GPU virtual space. UVD firmware reads at virtual
12 GB. Gap of 11.5 GB.

## What the patch DID do (verified)

- Built clean (incremental, ~2 min)
- Applied cleanly (`Applied: 0038-amdgpu-gmc-v7-0-liverpool-extend-vmid-va-range.patch`)
- Boot is functionally identical to v76b (USB/SATA/HID still work, SSH
  comes up at the same time)
- No regressions introduced — the wider VC[i]_END_ADDR didn't break GFX,
  SDMA, or any of the other working features

So the diagnostic value of v76d-α stands: **range is not the gate.** The
gate is the **absence of a valid PTE at the firmware's hardcoded VA.**

## Important: Sony's UVD fw access is NOT in the "cache" register set

Re-examining Sony's `uvd_vcpu_start_baikal` register writes:

```
0x3d82 (CACHE_OFFSET0) = 0
0x3d83 (CACHE_SIZE0)   = 0x7d000     (~500 KB)
0x3d84 (CACHE_OFFSET1) = 0xfa00      (~63 KB into VBASE)
0x3d85 (CACHE_SIZE1)   = 0x40000     (~256 KB)
0x3d86 (CACHE_OFFSET2) = 0x17a00
0x3d87 (CACHE_SIZE2)   = 0x120800    (~1.1 MB)
```

These three cache regions describe the **firmware text/data** itself.
Total ~1.4 MB of cache mappings, all from low addresses near VBASE=0.

The 0x300000000 access is NOT a cache read — it's some other access path.
Possible candidates:
- VCPU stack (firmware needs a stack somewhere in GPU VA)
- DMA descriptor buffer (the `0x40c2040` patterns at 0x3d79/3d7b)
- Save/restore area for context switching
- A hardware-specific scratch/IB queue

Whatever it is, the firmware hardcodes the VA `0x300000000`, and Sony's
gbase has a real mapping there. Our amdgpu doesn't.

## Decision: v76d-β path

The right next step is to **place a real (firmware-region) mapping at GPU
virtual 0x300000000** before starting UVD. Three approaches in order of
preference:

### v76d-β-1 (cheapest test): GART-extension experiment

Bump `adev->gmc.gart_size` from 512 MB to 16 GB on Liverpool/Gladius, so
the GART covers `0..0x400000000` (= 16 GB). This automatically gives all
16 VMIDs a PT large enough that the index for VA 0x300000000 exists. PTEs
for 0..512MB stay populated as before; PTEs for 512MB..16GB are zero so
the GMC will fall back to `mmVM_CONTEXT1_PROTECTION_FAULT_DEFAULT_ADDR`
(adev->dummy_page_addr).

If this works: firmware reads garbage but doesn't fault. The VCPU might
start (if the firmware tolerates zero/dummy responses) or fail at a
later stage with a different signature — both valuable signals.

Risks:
- GART table BO size increases proportionally (16 GB / 4 KB × 8 B = 32 MB,
  doubling our BO budget)
- GFX/SDMA share this GART; needs to not regress them
- amdgpu_gart_init has internal assumptions about size we'd need to check

### v76d-β-2: Bind a specific BO at VA 0x300000000

Allocate a small (4 MB) BO, bind it into the GART at virtual offset
0x300000000 via `amdgpu_gart_bind`. Requires GART size = ≥ 0x300400000
first (so this implies v76d-β-1 as a prerequisite).

If `amdgpu_gart_bind` works at arbitrary GPU VA, this gives the firmware
real memory to read from. We'd populate it with... probably zeros initially,
to see if the firmware accepts that.

### v76d-β-3: Custom PT for vmid 4 (mimic Sony)

Allocate a separate page-directory for vmid 4, populate the PD entry at
index 0x300000000 / 2 MB = 0x1800 with a PT page whose entries map to
the firmware physical pages.

Most faithful to Sony but biggest code change. Not the right first step.

## Recommended next iteration

**v76d-β-1**: bump GART size on Liverpool. Estimated ~30 min code +
incremental build. The decision criterion is whether the dummy-page
fallback path is sufficient or if we need real PT entries (β-2).
