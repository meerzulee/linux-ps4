# v76d-β-2-A3 — add PTE_WRITEABLE to UVD GART bindings

**Date:** 2026-05-11 21:32
**Result:** 🟡 **Zero VM faults — firmware runs cleanly but still doesn't reach STATUS bit 1.**
**UART log:** `checkpoint/uart-logs/2026-05-11_2132-v76d-beta2-a3-writeable.log`
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0043-amdgpu-ps4-uvd-gart-pte-writeable.patch`
**Build md5:** `72d39e9716e8d7d6fde071273cc23f5f`
**Boot:** clean — SSH up, no regressions.

## Fault count: 0

For the first time across the entire UVD iteration arc, **the dmesg
shows NO VM faults at all**. Compare:

| Iter | VM fault count |
|---|---|
| v76d-α / v76d-β-1 | 10 (PT walk fail) |
| v76d-β-2-A | 10 (null deref) |
| v76d-β-2-A1.5 | 0 (silent stall) |
| v76d-β-2-A2 | 187 (write-on-read-only) |
| **v76d-β-2-A3** | **0** |

A3 closed the last remaining permission gap. Firmware is alive,
executing, reading and writing freely in its region 1, and not
tripping any GMC fault.

## Same final symptom, different cause

The boot still ends with:
```
[12.076] [drm:uvd_v4_2_start.cold] *ERROR* ps4 uvd: Liverpool VCPU did not start (no STATUS bit 1 after 2s)
[12.086] [drm:uvd_v4_2_start.cold] *ERROR*   STATUS=0x00000004 SOFT_RESET=0x00000000 LMI_STATUS=0x00000004
```

STATUS=0x4 = bit 2 set, bit 1 not set. From Sony's `uvd_vcpu_start_baikal`
end-of-bring-up:
- success path: read 0x3daf bit 1 set → set 0x3d40 bit 1, clear 0x3daf bit 2
- timeout path: printk error (this is what we hit)

So the firmware never asserts "VCPU is ready" within 2 seconds. With
A3 the firmware is structurally healthy (no memory faults) — it's
spinning on some condition we haven't satisfied.

## What could be missing

Sony's region layout in vmid 4:
- Region 1: 0x300000000..0x3001E0000 (firmware target + save/restore)
- Region 2: 0x3001E0000..0x300304000 (heap/IB stage)
- Region 3: 0x300304000..0x300308000 (message queue)

We only bound region 1. If the firmware accesses regions 2/3 we'd
expect a VM fault — and we see none. So either:

(a) **The firmware doesn't touch regions 2/3 during init.** They're only
    used during decode work submission (heap = IB scratch, msgq = host
    communication). Init can complete without them.

(b) **The firmware DOES touch regions 2/3 but we missed mapping them**
    — no, that would fault, and we have zero faults.

So regions 2/3 are likely not the gate. Other candidates:

1. **mmUVD_VCPU_CACHE_OFFSET pointing wrong**: mainline writes
   `fw_gpu_addr - VBASE` which truncates to 32 bits = 0x00400000. Sony
   writes 0. If the VCPU's cache fetches from a wrong VA, it might
   load garbage into its internal cache memory and execute garbage —
   silently, since the GMC sees no faults from those reads.

2. **Missing companion-block enable**: Sony's bring-up writes 0x1401 bit 3
   (gfx_v7-side UVD client enable) and 0x501 = 3 (gfx_v7 final). If these
   don't happen on our path, the gfx ↔ UVD handshake breaks.

3. **Sony region 1 has init values beyond the firmware text** that we
   left as zero. The firmware might check for a magic byte or
   version field at some offset.

4. **Interrupt setup**: Sony's IRQ 0x7c is the UVD ITHREAD. Mainline
   uses irq 124 (same number). But the VCPU might be waiting for a
   bridge/companion interrupt that we never deliver.

## Next iteration candidates

### Most likely to move the needle

**A4: extend mirror to cover all 3 regions (1+2+3 = 0x308000, ~3.1 MB)**

Cheap incremental — alloc bigger BO, the upper part stays zero (just
needs to be mapped, not initialized). If region 2/3 mapping matters
for the firmware's idle handshake, we'll see STATUS bit 1 set.

If still STATUS=0x4 stall after A4: regions aren't the gate.

### Riskier but informative

**A5: instrument the existing register-write sequence in uvd_v4_2_start_liverpool**

Print every register read/write near the end (around udelay(16000) and
the STATUS poll), and additionally read 0x3d3c / 0x3d62 / 0x3d65 to see
their final values. Compare against Sony's expected sequence end-state.

**A6: change mmUVD_VCPU_CACHE_OFFSET0 to 0x300000000 << 12**

Sony's VBASE=0 + CACHE_OFFSET0=0 means cache fetches from virtual 0.
Mainline's truncated VRAM address might point the VCPU at a corrupted
location. Try pointing CACHE at region 1 directly.

## Boot health

- ✅ SSH up at usual time
- ✅ 0 VM faults
- ✅ No GFX/SDMA regressions
- ✅ Diagnostic prints all visible:
  - `ps4: VC1..VC15 PAGE_TABLE_DEPTH overridden to 0 (flat walk) for UVD compatibility`
  - `ps4: bound dummy page at GART virtual 0x300000000 (pa=0x1196000) for UVD fw access`
  - `ps4: bound dummy page at GART virtual 0x0 (pa=0x1196000) for UVD fw null-deref`
  - `ps4 uvd: bound fw mirror at GART virtual 0x300000000 (BO gpu_addr=0x93a000, fw_size=313912, region1_size=1966080)`

## Decision

**Recommend: A4** (extend mirror to all 3 regions). 10-line change. If
that doesn't shift STATUS, we know region mapping isn't the issue and
pivot to A5 (instrument) or A6 (CACHE_OFFSET retarget).
