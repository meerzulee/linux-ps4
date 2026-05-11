# UVD Dungeon Map — Ghidra (orbis-12.02.elf)

**Date:** 2026-05-11
**Status:** Extends `2026-05-11-uvd-vmid4-pt-investigation.md` with a broader survey of
UVD-related functions and their neighborhood (LMI, MC, GMC, ICC/SBL, gbase, gc/vm.c).
Goal: future-Claude can navigate the dungeon without re-walking it.

Program: `orbis-12.02.elf`, image base `0xffffffffc839c000`, 19,714 functions, x86-64.

---

## 1. Source-file map

Strings carry full source paths (FreeBSD-style `W:\Build\J02688428\sys\...`). The
clusters we care about:

| Path | What lives here |
|---|---|
| `sys/internal/modules/uvd/kmd/sce_gpkmd.c` | UVD KMD module entry + IOCTL handler |
| `sys/internal/modules/uvd/kmd/kmd_mem.c` | UVD buffer/lookup helpers (`FUN_c88f9230`) |
| `sys/internal/modules/uvd/kmd/kmd_interrupt.c` | UVD IRQ install/teardown (IRQ 0x7c) |
| `sys/internal/modules/vce/sce_gpkmd.c` | Separate VCE KMD module (mirrors UVD) |
| `sys/internal/modules/gc/vm.c` | GMC / GPUVM (gpu_reg_read/write, gbase_map_to_vmid0, vtophys) |
| `sys/internal/modules/gc/vmid0_va_allocator.c` | VMID0 VA allocator (gbase_alloc_va) |
| `sys/internal/modules/gc/memory_pstate.c` | memclk pstate + `gbase_set_gmc_config` |
| `sys/internal/modules/sbl/driver/handler.c` | SBL/ICC command bridge (`FUN_c89b80b0`) |
| `sys/freebsd/sys/kern/kern_dmem.c` | DMEM allocator (used by `uvd_alloc_region`) |

Build banner: ELF was compiled at `W:\Build\J02688428\...` — this is Sony's
official build machine path; matches PS4 12.02 FW.

---

## 2. UVD bring-up call graph

```
uvd_kmd_module_op            ffffffffc88f6270   module entry (param2: 0=init,1=fini)
  ├─ get_chip_family         ffffffffc8572e10   reads DAT_ca56ee80 & 0xfffffff0
  │                          → ctx.rev field at ctx+0x4c:
  │                            • 0x710f00..0x710f2f  → rev=0  (lvp_early)
  │                            • 0x710f30..0x710fff  → rev=1  (BAIKAL)        ← us
  │                            • 0x740f00..0x740f7f  → rev=2  (gladius)
  ├─ uvd_kmd_hw_init         ffffffffc88f6bc0   installs IRQ 0x7c, builds mutex
  │   ├─ intr_setup          (FUN_c8847f80) IRQ 0x7c → handler FUN_c88f6ca0
  │   └─ FUN_c8482770(0xfffffff0) — taskqueue / softc register
  └─ uvd_kmd_hw_init_stage2  ffffffffc88f8cf0   ← already plate-commented in Ghidra
      ├─ uvd_alloc_region(0x1E0000, 3, …) — 1920 KB firmware target
      ├─ uvd_alloc_region(0x124000, 0, …) — 1168 KB heap/IB stage
      ├─ uvd_alloc_region(0x4000,   0, …) —   16 KB message queue
      └─ memcpy(region1, fw_blob[rev], fw_size[rev])
          fw_blob[1] = ffffffffc8c67ff0, size 0x4ca38, banner
          "[ATI LIB=UVDFW,1.101.42]" at c8c67f70  ← Baikal firmware
```

**Total Sony UVD footprint = 0x308000 = 3,145,728 bytes ≈ 3.1 MB.**
Our v75 bumped Linux's UVD BO to 3.5 MB — slightly more than Sony but in the
same order. Size is not the v76 blocker.

### IOCTL surface (FUN_ffffffffc88f68e0, sce_gpkmd.c)

Param 2 is the ioctl number. Dispatch table:

| Cmd | Meaning | Calls |
|---|---|---|
| `0x20008301` | START decode | `uvd_vcpu_start_dispatch` |
| `0x20008302` | STOP decode | `FUN_c88f6e10` (per-chip wait_ready/teardown) |
| `0x80188304..7` | Submit IB / DMA op | `FUN_c88f6ef0/7020/70d0/7230` |
| `0x80188308..a` | Buffer mgmt | `FUN_c88f6e50` |
| `0x4004830b` | Get size | returns `0x20000` (128 KB) |
| `0x4008830c` | Get handle/address | returns constant `0x300308000` (note: contains `0x300000000` — same as the firmware fault addr!) |
| `0x403c8303` | Get perf counters | per-chip dump fn: lvp `c88f9710`, baikal `c88f7320`, gladius `c88fae50` |

The constant **`0x300308000` returned from `0x4008830c`** is striking — it falls
inside the `0x300000000..0x300400000` region the UVD firmware faults on in our
Linux port. This may be how the firmware learns where to read from. Cross-check
on next iteration.

### VCPU start dispatcher (FUN_ffffffffc88f6db0)

```
uvd_vcpu_start_dispatch(ctx):
  switch (ctx->rev) {
    case 2: prep = FUN_c88fafc0;       start = uvd_vcpu_start_gladius;     break;
    case 1: prep = uvd_vcpu_prep_baikal; start = uvd_vcpu_start_baikal;     break;
    default: prep = FUN_c88f9880;       start = uvd_vcpu_start_lvp_early;   break;
  }
  prep(); start(ctx);
```

`uvd_vcpu_prep_baikal` is a one-liner: `reg[0x3d2c] &= ~1`. This clears one bit
in a power/clock register before the main start sequence.

### Baikal VCPU start register sequence (uvd_vcpu_start_baikal, c88f8610)

See full decompile in §A; abbreviated annotation:

```
reg[0x3daf]    |= 4               UVD_STATUS: set BUSY
reg[0x3bd4/5/3] = 0x2011002       LMI clock cfg ×3
reg[0x3992/39c5/3993] = 0x2011002 Baikal-extra clocks (NOT in lvp_early)
reg[0x3d2a]    &= 0xfff00008      LMI clear
reg[0x3be4]    &= 0xffffe000      LMI? (Baikal-extra)
reg[0x398]     if &0x40000: &= ~0x40000   (conditional)
reg[0x3d98]    |= 0x200           VCPU CGC gate
reg[0x3d40]    &= ~2              state-machine reset
reg[0x3d6d/3d6f/3d68] = 0         audio/DMA mux clear
reg[0x3d66]    = 0x203108         mux cfg
reg[0x3d77]    = 0x10
reg[0x3d79]    = 0x40c2040        DMA desc 1
reg[0x3d7b]    = 0x40c2040        DMA desc 2
reg[0x3d7d]    = 0x88             DMA cfg
reg[0x3d68]    = 0x3dff           mux finalize
reg[0x3d3c]    = ctx[0x40] & 0xf  UVD_LMI_VCPU_CACHE_VMID  ← bits-of-rev0x40
;  indirect via 0x3d28 (INDEX) / 0x3d29 (DATA):
;    subreg 0x99  = packed (rev[0x40] bits)
;    subreg 0x9a  = packed (rev[0x40] bits)
;    subreg 0x162 = packed (rev[0x40] bits)
;    subreg 0x9b  &= ~0x10  (between two passes)
reg[0x3da3/3da1] = ctx[0x40] & 0xf
reg[0x3c5f] = 0; reg[0x3c5e] = 3      RBC priorities
reg[0x3d82] = 0
reg[0x3d83] = 0x7d000             cache region 1 size
reg[0x3d84] = 0xfa00              cache region 1 offset    ← Baikal uses LOW offsets
reg[0x3d85] = 0x40000             region 2 size
reg[0x3d86] = 0x17a00             region 2 offset
reg[0x3d87] = 0x120800            region 3 size
reg[0x3d98] |= 0x200              CGC retrigger
reg[0x3da9] = 0x11010000 + bit-twiddled              ← randomized hash bits
reg[0x3dab] = 1
ctx[0x2c] = 0x40000000000        ← `4 << 40` constant (probably stored copy of LMI_VBASE)
ctx[0x24] = 0x40000000000
reg[0x1401] |= 8                  UVD client enable (gfx_v7 side)
reg[0x3c69] = ctx[0x88] lo32      LMI_VM_VBASE_LO  ← documented in plate comment but v76a disproved
reg[0x3c68] = ctx[0x88] hi32      LMI_VM_VBASE_HI
reg[0x3da5/3da4] = 0              DMA reset
reg[0x3da9] &= 0xeffeffff
reg[0x3da0] &= ~1                 SOFT_RESET clear bit 0
; indirect subreg 0x9b &= ~0x10
reg[0x3dac] = 0x10
reg[0x3dab] |= 3
reg[0x3d98] &= ~0x40000
reg[0x3d3d] &= ~0x100
reg[0x3da0] &= ~4                 SOFT_RESET clear bit 2
reg[0x3da0] &= ~8                 SOFT_RESET clear bit 3
reg[0x3da0] &= ~0x2000            SOFT_RESET clear "RUN" bit  ← VCPU goes
udelay(16000)
poll reg[0x3daf] bit 1 set        VCPU ready, 2-sec timeout
  on success:
    reg[0x3d40] |= 2
    reg[0x3daf] &= ~4
    ctx[0x48] = reg[0x9e0]        save host link
    reg[0x9e0] = (cur & ~3) + 2   host link config
    reg[0x501] = 3                gfx_v7 final enable
  on timeout: printk SCEGPKMD f0a1:1b3
```

### Important caveat about the plate comment on `uvd_vcpu_start_gladius`

Ghidra's plate comment claims `reg[0x3c68/0x3c69]` (LMI_VM_VBASE_HI/LO) is the
"missing piece" vs upstream `uvd_v4_2_start`. That hypothesis was tested in
**v76a (commit 0ef06ff)** by both zeroing AND setting VBASE — neither changed
the fault address. So **the plate comment is historically accurate (Sony does
write VBASE that upstream doesn't) but the fault doesn't come from that.**

Don't follow that lead again. The next variables to probe are:
- ctx[0x40] (LMI_VCPU_CACHE_VMID etc.) — what value does Sony put in this byte?
- ctx[0x88] (the LMI_VBASE value itself) — what GPU VA does Sony point UVD at?

We can find ctx[0x40] / ctx[0x88] assignment sites by xref-walking from
`uvd_kmd_module_op` (allocates ctx) and the IOCTL handler.

---

## 3. UVD memory layout

`uvd_alloc_region(size, align_bits, &gpu_va_out, &kva_out, &pa_out)`:

```
FUN_ffffffffc86131c0(0,           // dmem segment 0
                     2,           // type 2 (system mem)
                     0,
                     0x2000000000, // VA range LOW   ← Sony's UVD system-VA range
                     0x2080000000, // VA range HIGH  (2 GB)
                     size, 0x4000, // 16 KB alignment
                     align_bits,
                     &gpu_va_out);
*kva_out = FUN_c8611790(...)      // kernel virtual addr (cpu side)
*pa_out  = FUN_c8801950(...)      // host PA list
FUN_c83f3950(*pa_out, *kva_out, mapping_type);
```

The range `0x20_0000_0000..0x20_8000_0000` is **FreeBSD direct-mapped system
memory**, not a GPU virtual address. After allocation, Sony uses `gbase_*` to
map the same physical pages into VMID 0 (kernel-GPU) or other VMIDs as needed.

So we shouldn't conclude UVD operates in vmid 4 just from this. The vmid is
set in ctx[0x40] separately.

---

## 4. MMIO infrastructure

`gpu_reg_read(idx)` and `gpu_reg_write(idx, val)` live at:
- `gpu_reg_read  @ ffffffffc8868ef0`
- `gpu_reg_write @ ffffffffc8867130`

Implementation (from plate comment + decompile):

```
if (idx < 0x8000):
    val = mmio_base[idx]            // direct
else:
    save = mmio_base[0]
    mmio_base[0] = idx << 2          // INDEX (byte offset = dword << 2)
    val = mmio_base[1]                // DATA
    mmio_base[0] = save               // restore
```

`mmio_base` = `DAT_ffffffffca76fdf8` (int*). Lock = `DAT_ca76fd78` (ICC mutex).

**Index convention: `idx` IS the DWORD offset** (matches upstream amdgpu's
`RREG32()` register numbering directly). So when Sony writes `reg[0x3d40]`
it's the same numeric value upstream calls `mmUVD_LMI_CTRL2` (one example).

Every Sony GPU subsystem (UVD, VCE, gfx_v7, sdma, dce, gmc) shares this
single MMIO window — `DAT_ca76fdf8` xrefs hit ~80 different functions in the
`c886xxxx`/`c887xxxx` cluster, which is Sony's port of amdgpu.

---

## 5. SBL / ICC bridge (FUN_ffffffffc89b80b0)

The handler at `sys/internal/modules/sbl/driver/handler.c:0x20e`:

```
sbl_call(cmd, &result_out):
  acquire(DAT_ca9e3518)
  mmio[0x22070] = 0xa404          // service id
  mmio[0x22074] = cmd             // command byte
  mmio[0x32]    = 1               // doorbell
  while (mmio[0x4a] & 1):         // wait for completion bit clear
    cv_wait(DAT_ca9e34f8, "waiting for intr")
  if (mmio[0x2207c] == 0):
    *result_out = mmio[0x22078]   // success: read result
  release(DAT_ca9e3518)
```

Known UVD-relevant commands:
- **`0xa5` → `uvd_lmi_clean_status`** (read-only) — used by `get_lvp_uvd_status`
  and `get_gl_uvd_status` to confirm LMI quiesce after stop

The ICC service IDs (0xa404) live in `mmio[0x22070]`. We have not yet enumerated
all UVD-related ICC commands; worth grepping for `FUN_c89b80b0(.,0x..` patterns
if a future iteration needs them.

The SMU side of SBL uses different MMIO ports (`0xc2100000` family) and is
called via `FUN_c89b85f0` (`sceSblDriverWriteSmuIx`) and `FUN_c885ba30`
(`sceSblDriverReadSmuIx`).

---

## 6. GMC / GPUVM (Sony's `gbase` layer)

### Naming map

| Sony term | Upstream equivalent | Notes |
|---|---|---|
| `gbase` | GPUVM / amdgpu_vm | Wraps the gc/vm.c API |
| `vmid0` | kernel VMID | Privileged GPU VA space |
| `gbase_map_to_vmid0` | amdgpu_vm_bo_map / gmc_v7_0_set_pte_pde | `FUN_c886ddf0` |
| `gbase_vmid0_vtophys` | gpuvm vtophys / amdgpu_vm_lookup | `FUN_c886b060` |
| `gbase_set_gmc_config` | gmc_v7_0_mc_init? | `FUN_c88581a0` — pstate-aware reconfig |
| `vmid0_va_allocator` | drm_mm range allocator | `FUN_c887b500` family |

### Debug-dump function (anchor for further exploration)

Sony has a sprawling GMC debug-dump function that prints every relevant register.
The strings are at `c8bac469`..`c8bad1b6`. Confirmed register-to-string mapping:

| Reg (DWORD idx) | mmReg name |
|---|---|
| `0x500` | `mmVM_L2_CNTL` |
| `0x801` | `mmMC_SHARED_CHMAP` |
| `0xa31c` | `mmCB_COLOR0_INFO` (CB) |
| `0x1509` | `mmCONFIG_CNTL` |
| `0xb00` | `mmHDP_HOST_PATH_CNTL` |
| `0x54f` | `mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR` (confirmed in prior session) |

**Critical observation**: Sony's debug strings enumerate
`mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR` through `mmVM_CONTEXT15_PAGE_TABLE_BASE_ADDR`
explicitly. So Sony's GMC bring-up programs all 16 VMIDs' PT base registers.
**VMID 4 IS programmed; we just haven't seen the writing code yet.**

The dump functions (e.g., `FUN_c8862990`, `FUN_c8862cb0`, `FUN_c8863280`,
`FUN_c8863380`, `FUN_c8863440`) are tiny — one `gpu_reg_read` + one `printk`
each — suggesting heavy inlining or a manual table. They are ALL marked
"WARNING: Subroutine does not return" in Ghidra because the printk is the
tail call.

### What we still need (carryover from v76c-γ')

To finish the dungeon: find Sony's GMC init writer. Approach:
1. xref-walk from any FB_LOCATION accessor (`FUN_c88595b0` per prior session)
   into its caller graph.
2. Search code for byte pattern that writes register `0x54f` (vmid 0 PT base) —
   the assembler form is likely `mov edi, 0x54f; mov esi, val; call gpu_reg_write`
   so search for `bf 4f 05 00 00`.
3. Same pattern for `0x553` (vmid 4 PT base) and `0x809` (FB_LOCATION).
4. Once located, decompile the parent function and document the full mc_init
   sequence here.

---

## 7. Chip-revision dispatch table

`uvd_kmd_module_op` selects `ctx->rev` (field at `ctx+0x4c`); three start
functions exist, identical in shape, differing in clock writes and cache
offsets:

| rev | chip | start fn | cache region 1 offset (`reg[0x3d84]`) |
|---|---|---|---|
| 0 | lvp_early (CUH-10xx/12xx) | `uvd_vcpu_start_lvp_early` (c88fa850) | `0xfa00` (64000) |
| 1 | **Baikal** (post-CUH-12xx Liverpool) | `uvd_vcpu_start_baikal` (c88f8610) | `0xfa00` (64000) |
| 2 | Gladius (PS4 Slim/Pro) | `uvd_vcpu_start_gladius` (c88fc140) | `0x20fa00` |

Differences worth noting between baikal and lvp_early:
- baikal writes 3 extra clock regs: `0x3992, 0x39c5, 0x3993`
- baikal writes `0x3c68/0x3c69` (LMI_VBASE) — lvp_early does NOT
- baikal uses INDEX/DATA subregs 0x99, 0x9a, 0x162 — lvp_early only uses 0x99, 0x9a
- baikal doesn't write `0x3d26` — lvp_early does (UCODE indirect cmd?)
- baikal uses `FUN_c88f6b70` (De Bruijn `__ffs`) to compute `0x3da9` — lvp_early uses constant

The two start sequences are upstream `uvd_v4_2_start` variants. For our Linux
port, copying `uvd_vcpu_start_baikal` literally into `uvd_v4_2_start` should be
~80% correct.

---

## 8. IRQ path (kmd_interrupt.c)

- IRQ vector `0x7c` (124)
- Primary handler: `FUN_c88f6ca0` — three-instruction wakeup:
  ```
  wakeup(DAT_ca5908c0, ctx+0x50)
  ```
- Worker (`FUN_c88f6c90`): `FUN_c8482820(arg, 0, 0)` — taskqueue enqueue
- Teardown: `uvd_kmd_hw_fini` calls `intr_remove(0x7c)` + lock_free

This is the standard FreeBSD ithread split: the hard ISR just notifies a
worker thread that drains UVD's ring/fence buffers.

For our Linux port: the IRQ line UVD wants is platform-dependent
(legacy IRQ 9-ish on Bonaire, MSI on later chips). With our `intremap=off`
+ force-MSI patch, amdgpu's UVD interrupt setup should "just work" if the
GMC mapping is right — Sony's IRQ 0x7c number is FreeBSD's internal IDT
slot, not directly transferable.

---

## 9. UVD status / diagnostics

Two near-identical functions for status snapshots:

- `get_lvp_uvd_status @ c8762ec0` — Baikal/lvp register dump (13 regs + ICC)
- `get_gl_uvd_status  @ c8528eb0` — Gladius (18 regs; adds 0x3d60, 0x3be2, 0x3be5, 0x39cc, 0x3c01)

Both call `FUN_c89b80b0(0xa5, …)` to fetch the LMI clean status via ICC. The
on-error printk string is `"failed to get uvd_lmi_clean_status"`.

### UVD diagnostic register list (Baikal subset, all from get_lvp_uvd_status)

| Reg | Comment |
|---|---|
| `0x3bc6` | UVD interrupt status |
| `0x3daf` | UVD_STATUS |
| `0x3d67` | LMI VCPU cache state (also polled at end of wait_ready for bits 6/9) |
| `0x3d42` | UVD_LMI_CTRL |
| `0x3d45` | UVD_LMI_??? |
| `0x3e41` | UVD ring/fifo |
| `0x3da0` | UVD_SOFT_RESET |
| `0x3df0` | UVD_??? |
| `0x3bdb`/`0x3bdd` | UVD_??? |
| `0x3d2b`/`0x3d2d` | UVD_??? |
| `0x3d98` | UVD_VCPU_CNTL |

If we add a similar dump to our Linux port (one-line `RREG32`s of each), we'd
have parity with Sony's debug surface — useful for `dmesg`-side comparisons.

---

## 10. Cross-reference summary for next iteration

When picking up v76c-γ', this is the minimum set of Ghidra addresses to keep
warm:

```
UVD entry           c88f6270  uvd_kmd_module_op
UVD bring-up        c88f8cf0  uvd_kmd_hw_init_stage2 (plate comment)
Baikal start        c88f8610  uvd_vcpu_start_baikal
Baikal prep         c88f7490  uvd_vcpu_prep_baikal
Wait ready          c88f74b0  uvd_vcpu_wait_ready
IOCTL handler       c88f68e0  (no name — sce_gpkmd.c)
Stop dispatcher     c88f6e10  (per-chip stop)
Region allocator    c88f94e0  uvd_alloc_region
DMA map             c88eb570  uvd_ctx_dma_map_buffer
MMIO read           c8868ef0  gpu_reg_read
MMIO write          c8867130  gpu_reg_write
MMIO base           ca76fdf8  DAT_*  (int* int the GPU window)
Chip family         c8572e10  get_chip_family
Chip family raw     ca56ee80  DAT_*  (chip id with low nibble)
SBL/ICC bridge      c89b80b0  (handler.c)
SBL SMU write       c89b85f0
gbase_map_to_vmid0  c886ddf0
gbase_vtophys       c886b060
gbase_set_gmc_config c88581a0 (memory_pstate dispatcher)
GMC programmer      c88584e0  (memory_pstate.c - SMU IX writes)
```

---

## 11. Implications for the v76c iteration

1. **Plate comment about VBASE is historical.** v76a disproved it. Look elsewhere
   for the missing piece — likely ctx[0x40] / LMI_VCPU_CACHE_VMID, ctx[0x88]
   firmware GPU offset value, or the GMC vmid 4 PT entry itself.

2. **All 16 VMIDs ARE programmed.** Sony's GMC init writes
   `mmVM_CONTEXT0..15_PAGE_TABLE_BASE_ADDR`. Mainline amdgpu only programs
   VMIDs 0/1 directly and lets VMIDs 2-15 share VMID 0's PT. Sony does NOT
   share — each VMID gets its own PT base. **This is likely the v76c key.**

3. **The `0x300308000` returned from ioctl `0x4008830c`** is inside the firmware
   fault region. If user-space passes this to the firmware as a "decode-output
   buffer" pointer, that's what we need to map in our port.

4. **Sony's 3.1 MB UVD footprint = ours 3.5 MB.** Size already-fine; not a
   variable to keep tuning.

5. **Sony's UVD VA is system-RAM-backed** (DMEM 0x20_0000_0000 range), then
   `gbase_*`-mapped into the GPU view. Upstream amdgpu's `AMDGPU_GEM_DOMAIN_GTT`
   is the equivalent. Don't switch to VRAM-domain BO for UVD.

6. **Cross-platform note:** Sony's `gpu_reg_read` uses the index/data fallback
   for regs ≥ 0x8000. Mainline amdgpu has the same trampoline but at different
   thresholds depending on aperture size; if we see a "small MMIO window"
   problem on PS4 it's the same root cause Sony works around.

---

## 12. GMC INIT FOUND — Sony's full GMC architecture (added in second pass)

After the initial map, byte-pattern hunting confirmed Sony's full GMC bring-up.
The vmid 4 mystery is now resolved.

### 12.1 The four canonical gbase functions

| Function | Address | Role |
|---|---|---|
| `gbase_init_global_vm_context0` | `c886e900` | Chip-boot GMC reset: all 16 vmids→safe page, all DISABLED, L2 cache init, AGP aperture, fault handlers |
| `gbase_create_vmid` | `c8867260` | Per-VMID: allocate own PD, program `mmVM_CONTEXT[i]_{PAGE_TABLE_BASE,START,END}_ADDR`, clear DISABLE bit, TLB invalidate |
| `gbase_map` | `c886a540` | VMID-aware mapper. Walks per-vmid PD, calls `gbase_write_pte` for each page |
| `gbase_write_pte` | `c88661c0` | Innermost: `pd[idx] = (pa & ~0xfff) \| (flags & 0xfff)` |

### 12.2 The CIK register numbering (now confirmed by code, not strings)

Sony writes these dword indices (matches mainline `gmc_7_0_d.h`):

| Reg | VMID range | Notes |
|---|---|---|
| `0x54f + vmid` | VC0..VC7 PT_BASE | `vmid << 12` |
| `0x506 + vmid` | VC8..VC15 PT_BASE | non-contiguous with VC0..VC7 |
| `0x557 + vmid` | VC0..VC7 PT_START | `va_start >> 12` |
| `0x50e + vmid` | VC8..VC15 PT_START | |
| `0x55f + vmid` | VC0..VC7 PT_END | `(va_start + va_size - 1) >> 12` |
| `0x51c + vmid` | VC8..VC15 PT_END | |
| `0x504` | VC0_CNTL | global write: `0x32fffeda`, then `\|= 1` at end |
| `0x505` | VC1_CNTL | global write: `0x32fffeda`, then `\|= 1` at end |
| `0x50c` | VC0_CNTL2 | `0x13` |
| `0x50d` | VC1_CNTL2 | `0x13` |
| `0x535` | VM_CONTEXTS_DISABLE | bit per vmid, 1=disabled |
| `0x500` | VM_L2_CNTL | `0xc0b8603` |
| `0x501` | VM_L2_CNTL2 | `3` |
| `0x502` | VM_L2_CNTL3 | `0x120000` |
| `0x546/0x547` | VC0/VC1_PAGE_TABLE_DEFAULT_ADDR | safe-page address |
| `0x80a` | MC_VM_AGP_TOP | `0x3fffff` |
| `0x80b` | MC_VM_AGP_BOT | `0` |
| `0x80c` | MC_VM_AGP_BASE | `0` |
| `0x80f` | MC_VM_SYSTEM_APERTURE_DEFAULT_ADDR | safe-page |
| `0x819` | MC_VM_MX_L1_TLB_CNTL | RMW: clear bit 0, then `& 0xffffff84 \| 0x5b` |
| `0x1412` | (TLB invalidate trigger) | written `=1` after every map |

### 12.3 The VMID allocation model

`gc_open` (FUN_c8878140, source `sys/internal/modules/gc/gc.c`) is the per-process
GPU client open syscall. It calls:

```
gc_open(proc):
  ...
  if (proc has no vmid yet):
    gbase_attach_process_vmid(ctx)              [FUN_c886f150]
      → gbase_alloc_vmid(&vmid, ...)            [FUN_c8865dc0]
        (bitmap pulls from DAT_ca76fd00/04/08)
      → gbase_create_vmid(vmid, 0, va_size, ...)  [FUN_c8867260]
        - alloc PD via gc_allocate_system_memory_for_dir
        - clear PD entries
        - write VC[vmid]_PT_BASE = pd_phys >> 12
        - write VC[vmid]_PT_START = 0
        - write VC[vmid]_PT_END   = (va_size-1) >> 12
        - clear VM_CONTEXTS_DISABLE bit
        - TLB invalidate this vmid
        - if vmid ∉ {0,15}: map kernel work area at GPU VA 0x7ffffc000
  ...
  reg[0x505] |= 0x10249248   // VC1_CNTL: enable fault handling
```

**VA range per vmid (from FUN_c886f150):**

| Cred class | "iVar1" flag | VA range |
|---|---|---|
| Kernel-credentialed process | (n/a) | `0..0x10000000000` = **64 GB** |
| Userland process, special flag set | `iVar1 != 0` | `0..0x8000000000` = **32 GB** |
| Userland process, no flag | `iVar1 == 0` | `0..0x2000000000` = **8 GB** |

`gbase_create_vmid_simple` (FUN_c886f2c0) is a parallel entry without process
ownership, called from `FUN_c8619740`. Its VA-range rules:

| vmid | VA range |
|---|---|
| 1 | 64 GB |
| 14 | 32 GB |
| other | 8 GB |

**VMID assignments observed in code:**

| VMID | Owner | Set by |
|---|---|---|
| 0 | Kernel GPU VA (1 TB!) | `FUN_c88487b0` PCI attach → `gbase_create_vmid(0, 0, 0xfc00000000, ...)` |
| 1-13 | Pool A (any process via `gc_open`) | `gbase_alloc_vmid` from bitmap |
| 14 | Reserved 32 GB slot | `gbase_create_vmid_simple(14, ...)` |
| 15 | SAMU | `FUN_c885af40` → `gbase_create_vmid(15, ...)` |

So **"vmid 4" in our v76 fault is whichever vmid the first GPU process happened
to get** — it's a dynamic alloc, not hardcoded. The constant is the *VA address*
the UVD firmware accesses (`0x300000000` = 12 GB).

### 12.4 What this means for our 6.x Linux port

Mainline `gmc_v7_0_gart_enable` (drivers/gpu/drm/amd/amdgpu/gmc_v7_0.c) has this
Liverpool-specific block (line ~691):

```c
if (adev->asic_type == CHIP_LIVERPOOL || adev->asic_type == CHIP_GLADIUS) {
    for (i = 1; i < 16; i++) {
        WREG32(mmVM_CONTEXT0_PAGE_TABLE_BASE_ADDR + i,
               adev->gart.table_addr >> 12);            // shared with VC0
        WREG32(mmVM_CONTEXT0_PAGE_TABLE_START_ADDR + i, 0);
        WREG32(mmVM_CONTEXT0_PAGE_TABLE_END_ADDR + i,
               (max_pfn - 1));                          // widen range
    }
}
```

The shared-PT model: all 16 VMIDs point to VMID 0's GART table, and the range
ends at `max_pfn - 1`. On PS4 with 8 GB GDDR5: `max_pfn = 0x200000 - 1` (8 GB
in 4 KB pages). So the VC1..VC15 range is `0..(8 GB - 1)`.

**UVD firmware accesses VA `0x300000000` (= 12 GB). That's OUT OF RANGE for the
8 GB max_pfn vmid 1..15.** When the firmware accesses `0x300000000`, the GMC sees:
- vmid (whatever it is) has START=0, END=(8GB - 1)
- requested VA 12 GB > END → out-of-range → VM fault
- → "GPU Protection fault" in the IH → exactly our v76 symptom

Sony's vmids have ranges of **8 GB, 32 GB, or 64 GB**. The 8 GB range is even
TIGHTER than what we have (slightly), but the 32 GB / 64 GB ranges ARE big
enough to cover 0x300000000. So in Sony's working case, UVD probably runs in a
32 GB or 64 GB vmid (a process with the "iVar1 != 0" cred flag, or vmid 1).

### 12.5 The v76d fix candidate

In the Liverpool-specific block of `gmc_v7_0_gart_enable`:

```c
// Was:
WREG32(mmVM_CONTEXT0_PAGE_TABLE_END_ADDR + i, (max_pfn - 1));

// Try (v76d):
WREG32(mmVM_CONTEXT0_PAGE_TABLE_END_ADDR + i, (0x8000000000ULL >> 12) - 1);
// = 32 GB - 1 page, matching Sony's "32 GB process" range
```

**Tradeoff to verify**: the PT itself is still only sized for `max_pfn` pages.
Extending the END_ADDR just tells GMC "look up VAs up to 32 GB" — but for VAs
beyond `max_pfn`, the PD entries are uninitialized/zero, which the GMC reads
as "no mapping". GMC then either:

1. Returns the **DEFAULT_ADDR** safe page (if VC[i]_CNTL bit `PAGE_TABLE_DEPTH=0`
   mode is set — Sony's `0x32fffeda` includes that), avoiding the fault, or
2. Faults on missing PTE (depending on PROTECTION_FAULT_ENABLE setting).

For UVD specifically, we need the firmware accesses to *resolve to real memory*.
That means either:
- Pre-populate PT entries at VA 0x300000000..0x300400000 to point to the
  firmware's physical pages (v76c-β proposal), or
- Set `mmVM_CONTEXT[i]_PAGE_TABLE_DEFAULT_ADDR` to the firmware's physical addr
  so out-of-range reads silently succeed (cheaper to try first, but reads will
  all hit the same page — won't work for writes or for varied access patterns).

**Recommend: v76d-α** = extend END_ADDR to 32 GB AND populate PT entries for
firmware region. Two-line GMC change + one PT-population call.

### 12.6 New address map (additions from second pass)

```
gbase_init_global_vm_context0  c886e900   chip-boot GMC bring-up
gbase_create_vmid              c8867260   per-vmid PT_BASE writer
gbase_create_vmid (thunk)      c8867240
gbase_create_vmid_simple       c886f2c0
gbase_attach_process_vmid      c886f150
gbase_alloc_vmid               c8865dc0
gbase_map                      c886a540
gbase_write_pte                c88661c0
gbase_init_mmio (sets DAT_*)   c88667b0
gbase_set_dc_hit_region        c886bc10
gc_open                        c8878140
samu_init                      c885af40    creates vmid 15
chip_specific_init             c8849210    calls gbase_init_global_vm_context0
pci_gpu_attach                 c88487b0    creates vmid 0 (1 TB!)

gbase per-vmid metadata        ca76fe30+   stride 0xf longs (120 B)
  +0x00  vmid
  +0x08  va_start
  +0x10  va_size
  +0x30  pd_kva
  +0x38  pd_handle
  +0x40  pd_gpu_phys   ← page-table-directory physical addr
  +0x68  dirent_array  ← per-PD-entry tracking

DAT_ca76fe08  safe page (4 KB, allocated in gbase_init_mmio).
              Used as VC[i]_PAGE_TABLE_DEFAULT_ADDR for all initially-disabled vmids.

Free-vmid bitmaps:
DAT_ca76fd00 = 0x40000000   pool A (kernel-cred vmid)
DAT_ca76fd04 = 0x3ffc0000   pool B (user process vmid)
DAT_ca76fd08 = 0x20000      pool C (system: 14, etc.)
```

---

## Appendix A — full register sequences

Decompiled inline at this commit; see Ghidra MCP for live state. Three start
functions decompile to ~140 lines each, all with `gpu_reg_read/write` calls
and `udelay`-bounded busy waits. The full body is preserved in this session's
transcript and was not duplicated here to keep this doc navigable.
