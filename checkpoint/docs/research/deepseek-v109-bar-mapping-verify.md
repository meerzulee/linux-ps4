# deepseek-v109-bar-mapping-verify.md — 2026-05-14

## Claim 1: global softc pointer at 0xffffffffca590938
**VERIFIED.**  Data region: 16-byte BSS slot, current_type=undefined8,
classification_hint=STRUCTURE.  3 xrefs: 1 WRITE (mts_attach @ 0xc85ec064:
`DAT_ffffffffca590938 = puVar5`), 2 READs (FUN_c85ebdd0 @ 0xc85ebdd7,
FUN_c85f25a0 @ 0xc85f25cd).  Single uint64_t holding the softc pointer.
Adjacent 8 bytes at +8 likely a separate variable (or padding).

## Claim 2: BAR0 struct resource* at softc + 0x3068
**VERIFIED.**  mts_attach line: `FUN_ffffffffc86065a0(param_1,
&DAT_ffffffffc9deaa30, puVar5 + 0x60d)` — stores resource* at
softc[0x60d] = byte offset 0x60d×8 = 0x3068.  mts_mac_init (@ 0xc85ecb60)
derefs: `plVar1 = (long *)(param_1 + 0x3068)` then `*plVar1` yields the
struct resource* for all subsequent BAR accesses.  Consistent throughout.

## Claim 3: KVA (bus_space_handle_t) at offset 0x10 in struct resource
**VERIFIED.**  mts_mac_init MMIO pattern: `*(long *)(*(long *)(param_1 +
0x3068) + 0x10)` extracts resource+0x10, then `+ 0xNN` adds BAR offset
(e.g. +0x200 for master reset, +0x50 for IRQ status).  Ghidra decompile
shows this exact pattern: `puVar9 = (undefined4 *)(*(long *)(*(long *)
(param_1+0x3068)+0x10)+0x200)`.  KVA is at offset 0x10.  **Confirmed not
0x18** — the 0x10 offset is used consistently for every BAR read/write.

## Claim 4: offset 8 = port/MMIO type flag (0=I/O, !=0=MMIO)
**VERIFIED.**  mts_mac_init branch pattern repeated for every register
access: `if (*(long *)(*(long *)(param_1+0x3068)+8) == 0) { out(...);
} else { *puVar9 = ...; }` — selects port-I/O (out/in) vs MMIO (direct
deref) path.  Consistent across all ~20 register accesses in mts_mac_init
and replicated in mts_intr, mts_init_rings_kick.  Zero = port I/O,
non-zero = MMIO (which is always the case — BAR0 is MMIO-allocated).

## Payload derivation

**Working path to BAR0 KVA:**
```c
uint64_t softc    = *(uint64_t*)0xffffffffca590938;  // global
uint64_t res_ptr  = *(uint64_t*)(softc + 0x3068);     // struct resource*
uint64_t bar_kva  = *(uint64_t*)(res_ptr + 0x10);     // bus_space_handle_t
// bar_kva is virtual address of BAR0 MMIO — readl(bar_kva+offset)
```

All 4 claims individually cross-verified against Ghidra decompile.
Convergence: hermes + deepseek agree on all offsets.  High confidence.

--- deepseek-v41, 2026-05-14
