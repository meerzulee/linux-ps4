# 2026-05-12 — Ghidra re-dig of orbis-12.02.elf: SAMU access pattern corrected

Triggered by the SBL-P1 v1 hardware test (see `2026-05-12-sbl-p1-result.md`)
which showed writes to `BAR5 + 0x22070..0x2207c, 0x32, 0x4a` had no SAMU
side effect — the addresses behaved like plain writable scratch memory.

The dungeon room (`orbis-dungeon/rooms/sbl-driver.md`) had captured the
sceSblDriverReadSmuIx pseudo-code as a single `samu_write(off, val)` /
`samu_read(off)` pair, treating all offsets — including `0x32` and
`0x4a` — as direct byte offsets in the same BAR. The hardware test
disproved that.

Re-decompiling the four functions in `gc/samu.c` separately in the live
Ghidra project resolved it. **Sony uses two register-access mechanisms
on the same BAR (BAR5 / rmmio), and the dungeon doc had silently
collapsed them.**

---

## The four real functions

All decompile against the existing orbis-12.02.elf project (load base
`0xffffffff`-prefixed). Full body in Ghidra; key snippets:

### `samu_write_direct` — `FUN_ffffffffc885b8a0`

```c
ulong samu_write_direct(uint off, uint val)
{
    puVar = (uint *)(off + *(long *)(DAT_ca726878 + 0x10));
    if (*(long *)(DAT_ca726878 + 8) != 0)
        *puVar = val;             /* MMIO path */
    else
        out((short)puVar, val);   /* PIO path — never taken on PS4 */
    return ...;
}
```

Plain `*(BAR5_base + off) = val`. Used for the **mailbox data regs**
at `0x22070..0x2207c`.

### `samu_read_direct` — `FUN_ffffffffc885b880`

Mirror of the above: `return *(uint *)(BAR5_base + off);`. Used for
reads of `0x22078` (return value) and `0x2207c` (status).

### `samu_ind_write` — `FUN_ffffffffc885b960`

```c
void samu_ind_write(uint idx, uint val)
{
    mutex_lock(&samuixmtx);
    *(uint *)(BAR5_base + 0x22000) = idx;   /* IND_INDEX */
    *(uint *)(BAR5_base + 0x22004) = val;   /* IND_DATA  */
    mutex_unlock(&samuixmtx);
}
```

**Indirect access** to a SAMU-internal register: pick the SAMU reg by
writing its index to BAR5 + `0x22000`, then the value to BAR5 + `0x22004`.

### `samu_ind_read` — `FUN_ffffffffc885b8d0`

Mirror: write `idx` to `0x22000`, read result from `0x22004`. Same
`samuixmtx` serialisation.

---

## Why the dungeon doc misread it

The dungeon transcribed `sceSblDriverReadSmuIx` from a higher-level
pseudo-decompile that already substituted `samu_write(...)` /
`samu_read(...)` for all four mechanisms. Without going one level
deeper to see which function was actually being called, the offsets
`0x32` and `0x4a` ended up alongside `0x22070..0x2207c` in the
documentation as if they were all the same access type.

Re-decompiling `sceSblDriverReadSmuIx` (`FUN_ffffffffc89b80b0`) shows
the four functions clearly:

```c
samu_write_direct(0x22070, 0xa404);   // c885b8a0 — direct
samu_write_direct(0x22074, smu_idx);  // c885b8a0 — direct
samu_ind_write   (0x32,    1);        // c885b960 — indirect (TRIGGER!)
while ((samu_ind_read(0x4a) & 1) != 0) {   // c885b8d0 — indirect
    // wait_for_intr
}
err = samu_read_direct(0x2207c);      // c885b880 — direct
val = samu_read_direct(0x22078);      // c885b880 — direct
```

---

## What this means for the Linux port

- Direct mailbox access: `BAR5 + off` for `0x22070..0x2207c` — already
  correct in our v1 code (proof: our writes persisted at those addresses).
- Trigger: was wrong. `0x32` is the SAMU's INTERNAL register index, not
  a byte offset in BAR5. We need to write idx `0x32` → `BAR5 + 0x22000`,
  then val `1` → `BAR5 + 0x22004`.
- Ack-poll: was wrong. Same indirect pattern with idx `0x4a`.

The v1 patch wrote `1` to BAR5 + 0x32 (some unrelated GPU reg) and read
ack from BAR5 + 0x4a (another unrelated reg, always 0). Hence the
SAMU never saw a kick, and the poll loop fell through instantly.

---

## Bonus context found while in the binary

### Where the BAR pointer comes from

`samu_init` (`FUN_ffffffffc885af40`) captures `DAT_ca726878 = param_1`.
The caller is the GPU device attach routine (`FUN_ffffffffc88487b0`),
which does:

```c
*(undefined4 *)((long)puVar5 + 0x3c) = 0x24;   /* rid 0x24 = BAR5 */
lVar3 = bus_alloc_resource(param_1, SYS_RES_MEMORY, &(softc + 0x3c), ...);
puVar5[8] = lVar3;                              /* softc.bar5_res */
... bus_get_handle, bus_get_tag ...
samu_init(puVar5[8]);                          /* pass BAR5 resource */
```

So Sony's SAMU access is via the same BAR Linux exposes as `adev->rmmio`
(BAR5, 256 KB at 0xE4800000 on our hardware). The 256 KB rmmio aperture
is enough to span both `0x22000` (the indirect window) and `0x22070..0x2207c`
(the direct mailbox window); the SAMU just happens to live in this region.

The other BARs (Region 0 = 64 MB VRAM aperture, Region 2 = 8 MB) are NOT
the SAMU surface, contrary to the BAR-sweep hypothesis at the end of
v1's result doc.

### Adjacent functions for future phases

- `FUN_ffffffffc8848eeb` calls samu_init from `FUN_ffffffffc88487b0` —
  the GPU attach entry point.
- Strings `samubmpmtx` (BMP = bitmap, for memory-region tracking) and
  `samuixmtx` (the indirect-access lock) localise the mutexes.
- `gbase_map_for_samu` / `gbase_unmap_for_samu` /
  `gbase_set_attr_for_samu` — the GPU VM helpers for mapping host pages
  into SAMU's VMID (15). Phase 2 territory.
- `samu: illegal cmd %d` / `samu: unknown cmd %d` / `samu: intst %#x(tsc:%lx)`
  — the SAMU interrupt handler's log strings. Find xrefs to wire up
  IRQ 0x98.

---

## Patch landed

`patches/6.x-baikal/0300-gpu-liverpool/0058-amdgpu-ps4-sbl-phase1-v2-direct-and-indirect-access.patch`

Adds `sbl_ind_write` / `sbl_ind_read` helpers and routes the trigger
+ ack through them. Direct mailbox accesses untouched. Debugfs surface
extended with raw `P` (direct read), `I` (direct write), `X` (indirect
read), `Y` (indirect write) commands so the next probe round can
sweep without a rebuild for every new offset.

0057 (the v1 patch) is commented out of the series; kept in tree as a
historical record of the wrong assumption + its disproof.

Build artefact: `output/6.x-baikal/bzImage` md5 `e115e78ff1cebbf197ea4eeb710dbce1`.

---

## Why the sceUbios partial ELF (`/home/meerzulee/Downloads/discord`) didn't help

Reconstructed from `00_elf_header.bin` + `02_sceUbios_runtime.bin` →
`/tmp/sceUbios_partial.elf`, imported as `sceUbios_partial.elf` in the
Ghidra project at `/sbl-port/`.

The ELF program header reports a `LOAD` segment of `0x14a65e8` bytes
(≈21.6 MB) but only ~192 KB of it was extracted. The strings of interest
(e.g. `"sceUbiosWriteSmuRegister failed. Addr=0x%08x Value=0x%08x"`,
`"PCI BAR error: pciMemoryBase=…"`) sit in the loaded RODATA at
`0x681054` / `0x682170` etc., but every code site that LEA's against
them is in the unloaded 21 MB tail. Ghidra found 0 functions in our
slice.

The orbis-12.02.elf path turned out to be more productive (and was
already loaded). The sceUbios artefact remains useful for future
phases — once a fuller dump appears, the `sceUbiosWriteSmuRegister`
function will reveal the BIOS-level SMU programming convention which
might be needed for cold-boot SAMU init in Phase 5+.
