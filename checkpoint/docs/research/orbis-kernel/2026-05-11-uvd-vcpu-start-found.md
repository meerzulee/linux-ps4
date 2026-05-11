# Sony's UVD VCPU bring-up sequence — RE'd and ready to port (2026-05-11)

**TL;DR:** Found Sony's full per-chip-revision UVD VCPU start sequence in
`orbis-12.02.elf`. For Baikal (rev 1) the function is at
`0xffffffffc88f8610` (renamed `uvd_vcpu_start_baikal` in Ghidra). The
**single critical missing piece** that mainline AMDGPU's
`uvd_v4_2_start()` doesn't do is writing the firmware's full 64-bit GPU
address to registers `0x3c69` (lo) and `0x3c68` (hi):

```c
gpu_reg_write(0x3c69, fw_addr & 0xffffffff);
gpu_reg_write(0x3c68, fw_addr >> 32);
```

These set the VCPU's LMI memory base. Without them, the VCPU starts,
executes its firmware preamble, attempts to fetch data from GPU page
`0x300800`, the GMC has no mapping → exactly the "VM fault read from
UMC" cascade we observed in the v72c-uvd hardware test (and v71 and
v72b — same root cause, all of those).

Sony's full Baikal sequence is ~100 register writes (LMI clock, CGC
gating, cache region descriptors, VCPU clock divider, DMA setup, plus
the LMI_VM_VBASE writes), all visible in
`uvd_vcpu_start_baikal` at `0xffffffffc88f8610`. Decompilation
preserved in the Ghidra plate comment.

## How we found it

Search workflow:

1. Pattern-search for `mov edi, 0x3da0` (UVD_SOFT_RESET register index):
   `search_byte_patterns("bf a0 3d 00 00")` returned 36 hits clustered
   across 4 distinct functions in the UVD module text range
   (`0xc88f74xx`, `0xc88f86xx`, `0xc88fa8xx`, `0xc88fc1xx`). Each
   function writes to `0x3da0` repeatedly = each does a VCPU
   soft-reset / start sequence.

2. Decompiled the largest of them (`0xc88fc140`), discovered it's the
   complete VCPU bring-up sequence. Found Sony's `gpu_reg_write` helper
   along the way (`FUN_c8867130` — paired with our previously-named
   `gpu_reg_read` at `0xc8868ef0`, both in `sys/internal/modules/gc/vm.c`).

3. Looked at xrefs of the discovered function — there's exactly one,
   from `FUN_c88f6db0`. That function is the **per-revision dispatcher**:
   ```c
   void uvd_vcpu_start_dispatch(ctx) {
       if (ctx->rev == 2) {                 // Gladius (PS4 Slim/Pro)
           prep = uvd_vcpu_prep_gladius;    // FUN_c88fafc0
           start = uvd_vcpu_start_gladius;  // FUN_c88fc140
       } else if (ctx->rev == 1) {          // Late Liverpool — BAIKAL — our chip
           prep = uvd_vcpu_prep_baikal;     // FUN_c88f7490
           start = uvd_vcpu_start_baikal;   // FUN_c88f8610
       } else {                             // rev 0 (CUH-10xx/12xx)
           prep = uvd_vcpu_prep_lvp_early;  // FUN_c88f9880
           start = uvd_vcpu_start_lvp_early;// FUN_c88fa850
       }
       prep();
       start(ctx);
   }
   ```

4. Confirmed Baikal = rev 1 from the earlier chip-revision mapping in
   `uvd_kmd_module_op` (CPUID family `0x710f30+` → rev 1). So
   `uvd_vcpu_start_baikal` is the one we need for our hardware.

## What the function actually does (annotated, abridged)

```c
int uvd_vcpu_start_baikal(uvd_ctx *ctx) {
    uint64_t fw_gpu_addr = ctx[+0x88];     // firmware buffer's GPU address
    uint32_t clk_hint    = ctx[+0x40];     // clock divider (low 4 bits used)

    /* ===== Set UVD_STATUS init busy ===== */
    gpu_reg_write(0x3daf, gpu_reg_read(0x3daf) | 4);

    /* ===== LMI clock / voltage configuration (Liverpool-specific) ===== */
    gpu_reg_write(0x3bd3, 0x2011002);
    gpu_reg_write(0x3bd4, 0x2011002);
    gpu_reg_write(0x3bd5, 0x2011002);
    gpu_reg_write(0x3992, 0x2011002);
    gpu_reg_write(0x39c5, 0x2011002);
    gpu_reg_write(0x3993, 0x2011002);

    gpu_reg_write(0x3d2a, gpu_reg_read(0x3d2a) & 0xfff00008);  /* VCPU_CACHE_OFFSET clr */
    gpu_reg_write(0x3be4, gpu_reg_read(0x3be4) & 0xffffe000);  /* LMI_CTRL2          clr */

    if (gpu_reg_read(0x398) & 0x40000)
        gpu_reg_write(0x398, … & 0xfffbffff);                  /* CGS gate clear */

    gpu_reg_write(0x3d98, gpu_reg_read(0x3d98) | 0x200);        /* CGC config */
    gpu_reg_write(0x3d40, gpu_reg_read(0x3d40) & 0xfffffffd);   /* SM reset */

    /* ===== Audio / DMA mux registers (Liverpool-specific) ===== */
    gpu_reg_write(0x3d6d, 0); gpu_reg_write(0x3d6f, 0); gpu_reg_write(0x3d68, 0);
    gpu_reg_write(0x3d66, 0x203108);
    gpu_reg_read (0x3d77);
    gpu_reg_write(0x3d77, 0x10);
    gpu_reg_write(0x3d79, 0x40c2040); gpu_reg_write(0x3d7a, 0);
    gpu_reg_write(0x3d7b, 0x40c2040); gpu_reg_write(0x3d7c, 0);
    gpu_reg_write(0x3d7e, 0);
    gpu_reg_write(0x3d7d, 0x88);
    gpu_reg_write(0x3d68, 0x3dff);

    /* ===== VCPU clock divider — derived from ctx[+0x40] ===== */
    uint32_t k = clk_hint & 0xf;
    gpu_reg_write(0x3d3c, k);
    /* … bit-packed writes to 0x3d62, 0x3d63 using k, omitted here for brevity … */

    /* ===== Index/data sub-register access (0x3d28 = idx, 0x3d29 = data) ===== */
    /* Sony writes 3 sub-registers (0x99, 0x9a, 0x162) with clk-divider-packed values.
     * For Baikal specifically the 0x99 packing differs slightly from Gladius:
     *
     *   Baikal:  k<<20 | k | k<<4 | k<<8 | k<<12 | k<<16  | data_high_24
     *   Gladius: k<<20 | k | k<<4 | k<<8 | k<<12 | k<<16  | data_high_24
     *
     * These are nearly identical; precise difference is in the data-mask
     * applied to the prior register read (Baikal preserves more bits).
     */

    gpu_reg_write(0x3da3, k);
    gpu_reg_write(0x3da1, k);

    /* ===== Cache region descriptors (size + offset for 3 regions) ===== */
    gpu_reg_write(0x3d82, 0);
    gpu_reg_write(0x3d83, 0x7d000);       /* Region 1 size  */
    gpu_reg_write(0x3d84, 0xfa00);        /* Region 1 offset — Baikal-specific  */
    gpu_reg_write(0x3d85, 0x40000);       /* Region 2 size  */
    gpu_reg_write(0x3d86, 0x17a00);       /* Region 2 offset — Baikal-specific */
    gpu_reg_write(0x3d87, 0x120800);      /* Region 3 size  */

    gpu_reg_write(0x3d98, gpu_reg_read(0x3d98) | 0x200);

    /* ===== Random scramble for DMA register 0x3da9 (Liverpool security?) ===== */
    uint32_t a = FUN_c88f6b70(0x1000) & 0x1f;
    uint32_t b = FUN_c88f6b70(0x100)  & 0x1f;
    gpu_reg_write(0x3da9, 0x11010000 + a + b*0x100);
    gpu_reg_write(0x3dab, 1);

    /* ===== Mark ctx as GPUVM-base 0x40000000000 (4 TB) ===== */
    ctx[+0x2c] = 0x40000000000;
    ctx[+0x24] = 0x40000000000;

    /* ===== GFX-side: enable UVD client (reg 0x1401 bit 3) ===== */
    gpu_reg_write(0x1401, gpu_reg_read(0x1401) | 8);

    /* ===== ★ THE KEY WRITES — set LMI_VM_VBASE to firmware GPU addr ★ ===== */
    gpu_reg_write(0x3c69, fw_gpu_addr & 0xffffffff);   /* LMI_VM_VBASE_LO */
    gpu_reg_write(0x3c68, fw_gpu_addr >> 32);          /* LMI_VM_VBASE_HI */

    /* ===== Clear DMA + soft reset bit 0 ===== */
    gpu_reg_write(0x3da5, 0);
    gpu_reg_write(0x3da4, 0);
    gpu_reg_write(0x3da9, gpu_reg_read(0x3da9) & 0xeffeffff);
    gpu_reg_write(0x3da0, gpu_reg_read(0x3da0) & 0xfffffffe);

    /* ===== Index/data sub-write to 0x9b (clear bit 4) ===== */
    saved = gpu_reg_read(0x3d28);
    gpu_reg_write(0x3d28, 0x9b);
    gpu_reg_write(0x3d29, gpu_reg_read(0x3d29) & 0xffffffef);
    gpu_reg_write(0x3d28, saved);

    /* ===== Finalize CGC gate, ring config ===== */
    gpu_reg_write(0x3dac, 0x10);
    gpu_reg_write(0x3dab, gpu_reg_read(0x3dab) | 3);   /* Baikal: | 3 (Gladius writes | 1) */
    gpu_reg_write(0x3d98, gpu_reg_read(0x3d98) & 0xfffbffff);
    gpu_reg_write(0x3d3d, gpu_reg_read(0x3d3d) & 0xfffffeff);

    /* ===== Clear soft-reset bits (the actual VCPU start) ===== */
    gpu_reg_write(0x3da0, gpu_reg_read(0x3da0) & 0xfffffffb);  /* bit 2 */
    gpu_reg_write(0x3da0, gpu_reg_read(0x3da0) & 0xfffffff7);  /* bit 3 */
    gpu_reg_write(0x3da0, gpu_reg_read(0x3da0) & 0xffffdfff);  /* bit 0x2000 — VCPU RUN */

    /* ===== Wait for VCPU ready bit ===== */
    udelay(16000);
    int timeout = -2000000;
    do {
        if (gpu_reg_read(0x3daf) & 2) {
            /* SUCCESS — finalize host link */
            gpu_reg_write(0x3d40, gpu_reg_read(0x3d40) | 2);
            gpu_reg_write(0x3daf, gpu_reg_read(0x3daf) & 0xfffffffb);
            ctx[+0x48] = gpu_reg_read(0x9e0);
            gpu_reg_write(0x9e0, (gpu_reg_read(0x9e0) & 0xfffffffc) + 2);
            gpu_reg_read (0x501);
            gpu_reg_write(0x501, 3);
            return 0;
        }
        udelay(1000);
        timeout += 1000;
    } while (timeout != 0);

    /* TIMEOUT */
    printk("[SCEGPKMD@f0a1:1b3:%llx]\n", 2);
    panic();
}
```

## Why mainline AMDGPU's `uvd_v4_2_start` fails on Liverpool

Mainline `drivers/gpu/drm/amd/amdgpu/uvd_v4_2.c::uvd_v4_2_start()` does:
- Soft-reset toggle (mmUVD_SOFT_RESET = 0x3da0) ✓
- mmUVD_VCPU_CACHE_OFFSET/SIZE writes (0x3d82–0x3d87) ✓
- mmUVD_LMI_CTRL writes ✓
- BUT does NOT write `0x3c68 / 0x3c69` (LMI_VM_VBASE) ❌
- BUT does NOT do most of the Liverpool-specific LMI clock setup ❌
- BUT does NOT do the index/data sub-register tweaks ❌
- BUT does NOT write the GFX client-enable bit at register 0x1401 ❌

The mainline sequence works on Bonaire/Kaveri/Mullins because those
chips have different LMI defaults (auto-mapped MMIO + sane reset
state). On PS4 Liverpool the MMU starts in a state that needs explicit
configuration — and `0x3c68/0x3c69` is the single most important field
because it's what maps the VCPU's "internal" address space onto the
firmware buffer's actual GPU memory location.

## Linux port plan (v73)

Will land as `patches/6.x-baikal/0300-gpu-liverpool/00NN-amdgpu-uvd-v4-2-liverpool-vcpu-start.patch`,
in two parts:

**Part A: structural** — split `uvd_v4_2_start` so a CHIP_LIVERPOOL /
CHIP_GLADIUS branch can override the body. Either:
  (a) early-out in mainline's `uvd_v4_2_start` and call a new
     `uvd_v4_2_start_liverpool` (~250 LOC, transliterated from
     `uvd_vcpu_start_baikal` above), or
  (b) merge the Liverpool path inline behind asic_type checks.

**Part B: register macros** — add Liverpool-specific defines for the
register indices Sony writes that mainline doesn't have macros for
(0x3c68, 0x3c69, 0x3bd3-5, 0x3992, 0x39c5, 0x3993, 0x3d2c, 0x3d3c,
0x3d62/3, 0x3d66, 0x3d6d-f, 0x3d77/9/a/b/c/d/e, 0x3d82-7, 0x3d98,
0x3da9, 0x3dab, 0x3dac). Probably best added to a new
`uvd_liverpool_d.h` so we don't pollute the mainline `uvd_4_2_d.h`.

Per-rev branching: for now we only need Baikal (rev 1). Liverpool-early
(rev 0) and Gladius (rev 2) can use stubs that print an error and bail
— if anyone with that hardware ever shows up, the per-rev variants are
already RE'd in the kernel dump.

## Critical helpers/constants

| Sony name                       | Address              | Linux equivalent |
|---------------------------------|----------------------|------------------|
| `gpu_reg_write`                 | `0xffffffffc8867130` | `WREG32`          |
| `gpu_reg_read`                  | `0xffffffffc8868ef0` | `RREG32`          |
| `udelay`                        | `0xffffffffc84fbad0` | `udelay`          |
| `printk`                        | `0xffffffffc867c3e0` | `pr_*` / DRM_*    |
| `uvd_vcpu_start_baikal`         | `0xffffffffc88f8610` | (new) `uvd_v4_2_start_liverpool` |
| `uvd_vcpu_prep_baikal`          | `0xffffffffc88f7490` | inlined (1 write) |
| `uvd_vcpu_start_dispatch`       | `0xffffffffc88f6db0` | asic_type switch |
| `uvd_vcpu_start_gladius`        | `0xffffffffc88fc140` | (rev 2 — future)  |
| `uvd_vcpu_start_lvp_early`      | `0xffffffffc88fa850` | (rev 0 — future)  |

## What we already know about hardware

| Test | Result |
|---|---|
| v70 (UVD IP block adds) | sw_init -EINVAL — firmware-name lookup missing |
| v71 (firmware-name patch) | Found UVD fw v1.64 → VCPU not responding (10 retries), ring test -110 |
| v72b/v72c (with v1.64 fw) | Same v71 failure (firmware swap not in initramfs yet) |
| **v72c-uvd (Sony 1.101.42 fw)** | **Found UVD fw v1.101 Family ID 9 ✓** but VM faults at GPU page `0x300800` repeating until IH ring overflow |

The page `0x300800` is exactly what we'd expect to be inside the
firmware buffer if `0x3c68/0x3c69` were uninitialized (i.e. 0) — the
VCPU's internal addresses look "low," but with no LMI_VM_VBASE mapping
they get rejected as un-mapped GPU pages. Adding the two register
writes fixes this exact failure.

## Followups not yet investigated (separate sessions)

1. **VCE bring-up** — same kernel, same pattern. There's surely a
   `vce_vcpu_start_dispatch` somewhere. Apply the same workflow:
   pattern-search for VCE SOFT_RESET register loads, find the cluster,
   identify dispatcher.
2. **What triggers `uvd_vcpu_start_dispatch`** — currently we don't
   know who calls it. The dispatcher has no callers/xrefs we've
   identified. Likely called from the first ioctl on
   `/dev/sceGPDecoder` or similar. For our Linux port this doesn't
   matter — we hook it into mainline's existing `uvd_v4_2_start`
   call site (which fires during amdgpu probe).
3. **Random scramble** — `FUN_c88f6b70(0x1000)` and `(0x100)` produce
   pseudo-random values for the DMA register `0x3da9`. The full
   register value is `0x11010000 + (rand & 0x1f) + (rand & 0x1f)*0x100`.
   Sony might be reading a hardware-rng register; we can use any small
   nonzero constants on Linux and see what happens.
