# v109: BAR mapping verification — Ghidra evidence

## Claim 1: Global softc pointer at 0xffffffffca590938

VERIFIED. Ghidra xrefs to 0xca590938:
- **WRITE** at `mts_attach+0x34` (0xffffffffc85ec064): `DAT_ffffffffca590938 = puVar5`
- **READ** at `FUN_ffffffffc85ebdd0` (0xffffffffc85ebdd7): loads softc via `lVar3 = DAT_ffffffffca590938`
- **READ** at `FUN_ffffffffc85f25a0` (0xffffffffc85f25cd): `lVar3 = DAT_ffffffffca590938`

This is a single global pointer (8-byte slot), not part of a larger struct. Consistent with FreeBSD `softc` pattern.

## Claim 2: softc + 0x3068 holds BAR0 resource pointer, used by mts_mac_init

VERIFIED. In `mts_mac_init`:
- `plVar1 = (long *)(param_1 + 0x3068)` — first thing after prologue
- BAR register writes use `*(long *)(*plVar1 + 0x10) + 0xNN` pattern consistently
- Example: `puVar9 = (undefined4 *)(*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + 0x200)` — BAR+0x200
- Example: `puVar10 = (uint *)(*(long *)(*plVar1 + 0x10) + 0x74)` — BAR+0x074
- Example: `puVar9 = (undefined4 *)(*(long *)(*plVar1 + 0x10) + 0x7c)` — BAR+0x07c

In `mts_attach`:
- `puVar9 = (undefined4 *)(*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + ...)` — same pattern

Offset 0x3068 is consistent across both functions. VERIFIED.

## Claim 3: struct resource KVA at offset 0x10

VERIFIED. The pervasive pattern in mts_mac_init is:
```
puVar9 = (undefined4 *)(*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + BAR_OFFSET)
```

This decomposes as:
- `param_1 + 0x3068` = pointer to struct resource*
- `*(long *)(param_1 + 0x3068)` = struct resource* (the pointer value)
- `*(long *)(that + 0x10)` = bus_space_handle_t (KVA) at offset 0x10 in struct resource

The conditional `if (*(long *)(*plVar1 + 8) == 0)` selects between `out()/in()` (port I/O, type=0) and `*puVar9 = val` (MMIO, type!=0). VERIFIED: offset 0x10 = KVA, offset 0x08 = type flag.

## Claim 4: Offset 0x08 is port/MMIO type flag (0 = port I/O, != 0 = MMIO)

VERIFIED. Every BAR register access in `mts_mac_init` uses:
```c
if (*(long *)(*plVar1 + 8) == 0) {
    out((short)puVar9, value);   // port I/O path
} else {
    *puVar9 = value;             // MMIO path
}
```

And for reads:
```c
if (*(long *)(*plVar1 + 8) == 0) {
    uVar = in((short)puVar9);    // port I/O path
} else {
    uVar = *puVar9;              // MMIO path
}
```

This matches FreeBSD's `struct resource` where:
- offset 0x08: `r_type` (int, SYS_RES_MEMORY=1 or SYS_RES_IOPORT=0)
- offset 0x10: `r_handle` (bus_space_handle_t, KVA for MMIO)

VERIFIED. On PS4, MTS BAR0 is MMIO, so offset 8 will be non-zero (likely 1) and offset 0x10 will hold the mapped KVA.

## Summary

| Claim | Verdict | Evidence |
|-------|---------|----------|
| 1: Global softc at 0xca590938 | VERIFIED | xrefs: 1 write (mts_attach), 2 reads |
| 2: softc+0x3068 = resource ptr | VERIFIED | `param_1 + 0x3068` used throughout mts_mac_init |
| 3: resource+0x10 = KVA | VERIFIED | `*(long*)(resource + 0x10) + BAR_OFFSET` pattern |
| 4: resource+0x08 = type flag | VERIFIED | `== 0` selects `out()`/`in()`, `!= 0` selects MMIO `*ptr` |

## For dumper code

Walk path: softc* at 0xffffffffca590938 → softc+0x3068 → resource* → resource+0x10 = KVA of BAR0 MMIO mapping. Read 4096 bytes from that KVA.