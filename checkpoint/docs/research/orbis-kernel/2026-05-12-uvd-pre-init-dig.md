2026-05-12 — Ghidra deep dig: pre-UVD Orbis init paths
==========================================================

Goal: figure out what Orbis touches *before* userspace IOCTLs UVD, in case
Sony's boot-time GPU setup leaves the chip in a state the UVD firmware
requires.

What runs at Orbis boot before UVD
----------------------------------

### chip_specific_init (`FUN_c8849210`)

Called once during Orbis kernel init. Pseudo:

```c
chip_specific_init(dev):
    /* gbase + vbios_patch + samu chains */
    cu_count = read_cu_count_from_pci()
    bios = read_atom_bios_from_dev88()
    sublob = patch_atom_bios(dev88_bios, bios, cu_count)
    gbase_vbios_init(dev->vbios, sublob, cu_count)
    free(sublob, cu_count)
    gbase_cail_init()           /* SerDes ring + RLC + SE0 redundancy probe */

    /* Six writes, none of which touch UVD register space */
    gpu_reg_write(0xcc, 0)
    gpu_reg_write(0xce, 0)
    gpu_reg_write(0xf8, 0); ...gpu_reg_write(0xfb, 0)

    gbase_init_global_vm_context0()
```

The "six writes" are early-init scratchpads (0xcc..0xfb, not UVD's 0x3c00+
range). **No UVD register is touched in `chip_specific_init`.**

### gbase_init_global_vm_context0 (`FUN_c886e900`)

Sets up GMC for VC0 (system PD) and the per-VMID PD register array. Key
writes (offsets relative to ATOM BIOS register file `DAT_ca76fdf8`):

| Register field | Value | Meaning |
|---|---|---|
| `[0x546]`, `[0x547]` | `boot_pd_phys >> 12` | VC0/VC1 boot PT_BASE |
| `[0x504]`, `[0x505]` | `0x32fffeda` | **VC0/VC1 CNTL value Sony uses** |
| `[0x50c]`, `[0x50d]` | `0x13` | VC0/VC1 START_ADDR_HI (high bits = `0x13_xxxxxxxx`) |
| `[0xf93]`, `[0x80d]` | `0` | Dummy-page protection regs |
| `[0x80e]` | `0x47ffff` | Dummy-page END |
| `[0x80c]`, `[0x80b]`, `[0x80a]` | `0`, `0`, `0x3fffff` | Dummy-page upper-32 etc |
| `[0x500]` | `0xc0b8603` | **mmMC_VM_FB_LOCATION** (FB_BASE/FB_TOP) |
| `[0x501]` | `3` | mmMC_VM_FB_OFFSET |
| `[0x502]` | `0x120000` | mmMC_VM_AGP_BASE / something |
| `[0x819]` mask | `& ~1`, then `| 0x5b` (kept low 7 bits) | mmHDP_NONSURFACE_INFO write-protect ack |

Then a loop over vmid 0..15:
- Set bit in mask register `[0x535]` (enable VMID)
- Write VC*_PAGE_TABLE_BASE_ADDR = same boot PD
- Set VC*_START / VC*_END to 0 / 0 (all VMIDs initially zero-range)
- `gbase_invalidate_tlb(vmid)`

Then enables VC0/VC1 by `OR`-ing bit 0 into their CNTL.

**Key observation:** at boot, ALL VC0..VC15 point at the same boot PD with
empty (zero-range) per-vmid ranges. `gbase_create_vmid` later **overwrites**
specific VMIDs with their own PD and proper VA range.

### gbase_create_vmid (`FUN_c8867260`)

Allocates per-vmid PD + writes per-vmid registers. Confirms layout details:

- PD allocated via `kmem_alloc_contig(va_size >> 0x17 * 8)` (8 MB per PD
  entry, hence `>> 23`).
- VC*_PAGE_TABLE_BASE_ADDR = PD physical >> 12
- VC*_START_ADDR = va_start >> 12
- VC*_END_ADDR = (va_start + va_size - 1) >> 12
- For VMIDs ≠ 0 and ≠ 15: allocates a 16 KB "kernel work area" buffer,
  maps it at VA **`0x7ffffc000`** (top of 32 GB − 16 KB) with flags
  `0x161` (= VALID | READABLE | WRITEABLE | FRAG=2; **bit 1 / SYSTEM
  NOT set**).
- For VMID 1 specifically: also recursively calls
  `gbase_clear_vmid(2,0,0)`, `gbase_clear_vmid(3,0,0)`.

**Implication for B1:** Sony maps a per-vmid kernel work area at
`0x7ffffc000`. Our B1 PD only maps the fw mirror region (0x300000000).
If the UVD fw ALSO reads `0x7ffffc000`, we'd PT-fault. We have not seen
faults at that VA in our IH dumps, so probably not — but worth checking
after B1 boot.

### gbase_write_pte (`FUN_c88661c0`)

Confirms PTE/PDE encoding:

```c
gbase_write_pte(vm, pd_entry_idx, &pd_entry_slot, phys, va, count_pages, flags):
    pt = vm->pt_array[pd_entry_idx]
    if (!pt):
        pt = alloc_pt_page_from_pool()       /* 16 KB pool slot */
        vm->pt_array[pd_entry_idx] = pt
        *pd_entry_slot = pt_phys | 1          /* PDE: just VALID bit */
    pt[(va >> 12) & 0x7ff] = phys & ~0xfff | (flags & 0xfff)
    for count_pages: ... advance phys by 0x1000 ...
```

PT entry stride: `(va >> 12) & 0x7ff` → **2048 entries per PT page** =
**16 KB PT page**. Confirms block_size=11 (Sony's setting).

SBL/SMU IPC discovered (but NOT used during UVD bring-up)
---------------------------------------------------------

Hunting for "uvd" + reading callers of `FUN_c89b80b0` ("waiting for intr",
`sbl\driver\handler.c`) reveals **Sony's SMU access path**:

```c
sceSblDriverReadSmuIx(smu_index, &out_value):           /* FUN_c89b80b0 */
    samu_write(0x22070, 0xa404)         /* SBL read-SMU service id */
    samu_write(0x22074, smu_index)
    samu_write(0x32, 1)                 /* trigger interrupt to SBL */
    while (samu_read(0x4a) & 1):        /* poll until SBL acks */
        block_on_signal()
    err = samu_read(0x2207c)
    if (!err): *out_value = samu_read(0x22078)
    return err

sceSblDriverWriteSmuIx(smu_index, value):               /* FUN_c89b81d0 */
    samu_write(0x22070, 0xa505)
    samu_write(0x22074, smu_index)
    samu_write(0x22078, value)
    samu_write(0x32, 1)
    while (samu_read(0x4a) & 1): block_on_signal()
    return samu_read(0x2207c)
```

`samu_write/read` (FUN_c885b8a0/c885b8d0) reads/writes at base + offset
where base is stored at `DAT_ca726878 + 0x10`. Source file path: `gc/samu.c`.

So Sony talks to the **SAMU security co-processor** via an internal
mailbox at SAMU mmio offset 0x22070..0x2207c, with trigger at 0x32 and
ack at 0x4a. The SAMU forwards commands to the SBL/security-of-chip,
which can then read/write SMU registers (locked from CPU on retail).

**Critical for UVD:** the callees of `uvd_vcpu_start_baikal` are
**only** `gpu_reg_read`, `gpu_reg_write`, `printk`, `udelay` and one
internal sub-function `FUN_c88f6b70`. NO `sceSblDriver*` calls during
UVD bring-up. Sony does NOT program SMU at UVD-init time.

Possible UVD interrupt path
---------------------------

`uvd_kmd_hw_init` registers IRQ 0x7c (= 124, mainline's UVD trap IRQ)
with handler `FUN_c88f6ca0`:

```c
FUN_c88f6ca0(intr_frame):
    FUN_c85e3b00(DAT_ca5908c0, intr_frame + 0x50)  /* dispatch to vector handler */
```

Generic interrupt dispatch — does not directly drive UVD state.

What's NOT in Orbis pre-UVD init
--------------------------------

- No UVD-specific writes during `chip_specific_init` or
  `gbase_init_global_vm_context0`
- No `sceSblDriver*` IPC during UVD bring-up
- No ATOM BIOS execution that touches UVD (verified by grep: no UVD
  register writes in `vbios_patch`-related functions)
- No power-on / clock-init of UVD via SMU before bring-up (no
  `set_uvd_clock` symbol exists; UVD code paths only call gpu_reg_*)

Conclusion
----------

Sony's pre-UVD-init paths set up GMC and global VM context, but they do
**not** prepare anything UVD-specific. The UVD firmware bring-up is purely
register writes by `uvd_vcpu_start_baikal` (which we replicate).

**This means the gate to STATUS bit 1 is NOT "missing Orbis-side
pre-init."** Whatever the fw is waiting for must be one of:

1. **PD walk shape** — B1 tests this (different shape may unlock the fw).
2. **Chip state preserved from Orbis runtime** that we don't replicate
   in mainline amdgpu's PS4 init (clocks/DPM levels set at boot but not
   touched at UVD time).
3. **Memory mapping we missed** — e.g., the kernel work area at
   `0x7ffffc000` per vmid (Sony maps this for every non-special VMID;
   we don't).
4. **An interrupt or signal we don't fire** to the fw post-start.

B1 will test (1). After B1's hardware result we have:

- B1 ✅ → done, structural PD shape was the gate.
- B1 ❌ → next iteration: **add `0x7ffffc000` mapping to the PD** (cheap
  test of #3). If that doesn't fire either → #2 is structural and likely
  requires SBL/SMU access from Linux that we don't have, → graceful-fail
  and pivot to other features.

Reference: useful addresses for next session
--------------------------------------------

| Symbol | Address | What |
|---|---|---|
| `uvd_kmd_hw_init` | `c88f6c80` | Sony's UVD module init |
| `uvd_vcpu_start_baikal` | `c88f8610` | Sony's UVD VCPU bring-up |
| `uvd_vcpu_start_dispatch` | `c88f6dc7` area | Sony's start dispatcher |
| `gbase_create_vmid` | `c8867260` | Sony's per-VMID PD allocator |
| `gbase_write_pte` | `c88661c0` | Sony's PT entry writer |
| `gbase_init_global_vm_context0` | `c886e900` | Sony's boot-time GMC init |
| `gbase_update_vddnb` | `c8855fd0` | Sony's NB voltage updater (via SBL) |
| `sceSblDriverReadSmuIx` | `c89b80b0` | Sony's SBL→SMU read |
| `sceSblDriverWriteSmuIx` | `c89b81d0` | Sony's SBL→SMU write |
| `samu_write` | `c885b8a0` | SAMU register write |
| `samu_read` | `c885b8d0` | SAMU register read |
| `chip_specific_init` | `c8849210` | Sony's chip-level bring-up |

UVD VMID kernel work area
-------------------------

If B1 doesn't fire STATUS bit 1, the next cheapest test is to add a
mapping for `0x7ffffc000` (16 KB) into the B1 PD. Plain GTT-domain BO
backed by `kmalloc(16384)` is fine; Sony uses flags 0x161 (VALID |
READABLE | WRITEABLE | FRAG=2). The PT walk for that VA at block_size=11:

- PD index = `0x7ffffc000 >> 23` = `0xFFF`
- PT page covers VAs `0x7ff800000..0x800000000` (the last 8 MB of the
  32 GB range)
- 16 KB region = 4 pages starting at offset `(0x7ffffc000 & 0x7fffff) >> 12`
  = `(0x7fc000) >> 12` = `0x7fc` (entries 0x7fc..0x7ff in PT page)

Implementation: same pattern as B1's PT for region 1+2+3 but for the work
area's 4 pages. Allocate a 2nd PT page (16 KB), populate, write to
`PD[0xFFF]`.
