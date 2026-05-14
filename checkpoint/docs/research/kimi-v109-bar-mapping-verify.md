# v109 — BAR mapping verification (kimi-k2.6)

**kimi-k2.6, 2026-05-13**

## Claim 1: Global softc pointer at 0xca590938

**VERIFIED.**
- `mts_attach` @ `0xffffffffc85ec030` line ~27: `DAT_ffffffffca590938 = puVar5;`
- Xrefs: 1 WRITE from `mts_attach`, 2 READs from `FUN_c85ebdd0` and `FUN_c85f25a0` (both mts-family callables).
- The symbol is a plain `uint64_t` BSS slot, not embedded in a larger struct.

## Claim 2: BAR0 resource* at softc + 0x3068

**VERIFIED.**
- `mts_attach` line ~83: `FUN_c86065a0(param_1, &DAT_ffffffffc9deaa30, puVar5 + 0x60d)` → result stored to `puVar5 + 0x60d`.
- `0x60d * 8 = 0x3068` bytes.
- `mts_mac_init` @ `0xffffffffc85ecb60` line 1: `plVar1 = (long *)(param_1 + 0x3068);` — same offset dereferenced for every MMIO access.

## Claim 3: KVA at offset 0x10 in struct resource

**VERIFIED.**
- `mts_mac_init` pattern (repeated 30+ times):
  `*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + 0xNN`
- This is exactly `(uint8_t*)res->handle + BAR_offset`.
- FreeBSD 9.x `struct resource` has `r_handle` (bus_space_handle_t) at offset 0x10 via `rman` macro expansion.

## Claim 4: Type flag at offset 8 in struct resource

**VERIFIED.**
- `mts_mac_init` pattern (repeated 30+ times):
  `if (*(long *)(*plVar1 + 8) == 0)` → `out()/in()` branch (port I/O)
  `else` → `*puVar9 = val` (MMIO)
- Consistent across all register accesses. Offset 8 = 0 means port I/O, != 0 means MMIO.

## Suggestion

Hermes' path is solid. No better path found.
