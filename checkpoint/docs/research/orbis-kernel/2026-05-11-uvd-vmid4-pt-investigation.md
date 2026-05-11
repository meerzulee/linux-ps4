# UVD VCPU fault at virtual 0x300000000 in vmid 4 — investigation notes

**Date:** 2026-05-11 (end of v75 → v76b iteration session)
**Status:** Open question. Three variables eliminated (BO size, LMI_VM_VBASE, LMI_ADDR_EXT/EXT40_ADDR). Sony's GMC setup for vmid 4 not yet located in Ghidra.

## Where we ended up

Sony's UVD VCPU firmware does a deterministic memory access at GPU virtual byte `0x300000000` in vmid 4. Three iterations today confirmed this is **not** computed from any register we control:

| Iteration | Variable changed | Fault page |
|---|---|---|
| v74 | baseline | 0x300000 (= byte 0x300000000) |
| v75 | BO size: 2.7 MB → 3.5 MB | 0x300000 (no change) |
| v76a | LMI_VM_VBASE: 0xf00400000 → 0 | 0x300000 (no change) |
| v76b | LMI_ADDR_EXT/EXT40_ADDR: → 0 | 0x300000 (no change) |

The fault is firmware-hardcoded. Sony's UVD blob targets virtual `0x300000000` in its memory accesses, and we need GMC vmid 4 to satisfy that.

## How mainline AMDGPU sets up vmid 4

`gmc_v7_0_gart_enable` (drivers/gpu/drm/amd/amdgpu/gmc_v7_0.c, line 658-687):

- VMID 0 page table covers `gart_start..gart_end` (~512 MB GART range)
- VMID 1-15 all share VMID 0's `table_addr` (= `amdgpu_bo_gpu_offset(adev->gart.bo)`)
- For Liverpool/Gladius, VMID 2-7's translation range is widened to `0..max_pfn` (Liverpool-specific block at line 691-702)
- VMID 1+ are 2-level page tables (PAGE_TABLE_DEPTH=1)

Aperture configuration:
- System aperture (`mmMC_VM_SYSTEM_APERTURE_LOW/HIGH_ADDR`) covers VRAM physical range
- AGP aperture (`mmMC_VM_AGP_BOT/TOP/BASE`) is disabled (`AGP_BOT > AGP_TOP`)
- VRAM aperture (`mmMC_VM_FB_LOCATION`) places VRAM at virtual `0xf00000000..0xf3FFFFFFF`

For virtual `0x300000000`:
- Not in VRAM aperture (0xf00000000+)
- Not in GART range (0..0x1FFFFFFF)
- Not in any active aperture
- Walks the shared page table → no entry → VM fault

## Ghidra findings (this session)

Bonaire register IDs (from `gmc/gmc_7_0_d.h`):
| Register | ID |
|---|---|
| mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR | 0x54f |
| mmVM_CONTEXT0_PAGE_TABLE_START_ADDR | 0x557 |
| mmVM_CONTEXT0_PAGE_TABLE_END_ADDR | 0x55f |
| mmVM_CONTEXT0_CNTL | 0x504 |
| mmVM_CONTEXT1_CNTL | 0x505 |
| mmMC_VM_AGP_TOP/BOT/BASE | 0x80a/0x80b/0x80c |
| mmMC_VM_FB_LOCATION | 0x809 |

Byte pattern searches (`bf XX 0Y 00 00` = `mov edi, regid`):
- **All hits for `0x54f`, `0x550`, `0x551`, `0x552`, `0x553`** (VMID 0..4 PT base) land in **register-DUMP code** (e.g., debug print walker at `FUN_c8862xxx` and the userspace debug IOCTL handler `FUN_c887f610` in `dbggc.c`)
- **No write-pattern hits for these registers** found in 30 min of byte-pattern search
- Hits for `mmVM_CONTEXT_CNTL` registers (`0x504`, `0x505`) at `c8878a2e`, `c887d16e`, `c887d1ea`, etc. — all OR-equal `0x10249248` to re-enable faults (fault handler / per-process open). Not initial setup.

Specific functions identified:
- `FUN_c887c980` — Sony's VM fault handler, reads `0x537`/`0x536`/`0x53f` (fault status/addr), prints "GPU Protection fault. vmid: ... client: ... access: ..."
- `FUN_c8878140` — `gc_open` (graphics client open, per-process)
- `FUN_c88595b0` — converts offset to VRAM virtual address via `fb_location << 24`. Confirms Sony's `FB_LOCATION` register holds the high 8 bits of the VRAM virtual base, shifted left by 24

## Why the GMC init wasn't found

- The Orbis 12.02 ELF has ~19,000 functions
- GMC init is called once at chip boot, not per-process
- The function isn't named "gmc_init" or "vm_init" in our search — symbols are 99% stripped
- It would write `mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR + 0..15` with specific page-table-root values, plus configure apertures and CNTL registers
- 30 min of byte-pattern search was insufficient; needs structured xref walking from known-good calls

## v76c paths (in priority order)

### v76c-γ' — deeper Ghidra session (preferred next step)
Continue from where this session ended:
1. Search for full WRITES (not reads/OR's) of `mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR` (0x54f) — should find Sony's PT root assignment
2. Search for writes of `mmVM_CONTEXT0_PAGE_TABLE_START/END_ADDR` (0x557/0x55f) — finds vmid range configuration
3. Walk xrefs from FB_LOCATION accessor (FUN_c88595b0) — its caller(s) likely include GMC init or chip bring-up
4. Search for the string `"vm.c"` or `"sys/internal/modules/gc/vm.c"` in code references — Sony's source-path debug strings often appear near the function that comes from that file. `gpu_reg_read` had `vm.c:0x677` so GMC code is in vm.c.

Once we find what Sony writes for vmid 4 (PT_BASE, START, END, CNTL, plus any aperture programming), v76c becomes a clear port: replicate the same mainline-side.

### v76c-α — AGP aperture experiment (if Ghidra dig doesn't yield more)
Enable AGP aperture to map virtual `0x300000000..0x300400000` to a system-RAM buffer containing the firmware. Cost: ~1 hour code (BO domain shift, DMA-coherent buffer, three register writes); high risk of confusing results because AGP semantics for VRAM-resident BOs are unclear.

### v76c-β — manual page-table entry
Allocate a custom PT BO; populate one entry at virtual page `0x300000` pointing to fw physical pages; write the BO's GPU offset to `mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR + 4` (vmid 4 specific PT base). Cost: ~2 hours code; risk of getting PT format wrong (2-level PD/PT encoding for Bonaire).

### v76c-δ — relocate VRAM aperture (probably bad)
Change `mmMC_VM_FB_LOCATION` to put VRAM at `0x300000000` instead of `0xf00000000`. This works at the GPU level but breaks every other amdgpu user (dce, gfx) that hardcodes `0xf00000000`. Don't do this.

## Suggested order for next session

1. (~30-60 min) v76c-γ' — find Sony's GMC init in Ghidra. This is the cheapest and most informative move.
2. If found: port the relevant writes to a new patch (0038) in `0300-gpu-liverpool/`. Build, USB-test.
3. If not found in 60 min: switch to v76c-β (manual PT entry) — known mechanism, just labor.
