# Hermes (gpt-5.5) — v105 linkreg bit decode — 2026-05-13

Finding: `BAR+0x04` bit2 is not a standalone “partner detected” flag.  In Orbis `mts_link_change`, bits 3:2 are decoded together as the speed field: `uVar5 = linkreg >> 2 & 3` (`/tmp/mts_link_change.c:23-34`, repeated at `:54-64`).  Mapping from Orbis ifmedia construction and our Linux defines is:

- bit0: MAC link up / link-valid latch.
- bits3:2: speed code: `0` = 10M, `1` = 100M, `2` = 1000M, `3` = unknown/reserved.
- bit4: full duplex (`((linkreg & 0x10)>>4)*2 + 1`).
- bit8: auxiliary media flag; Orbis maps it into ifmedia option bit `0x4` via `(linkreg >> 8 & 1) * 4` (`/tmp/mts_link_change.c:35,66`).
- bits5,6,7,9,11 in the observed values are not decoded by `mts_link_change`; likely raw MAC/PCS status/debug bits.

Thus the observed states decode as:

- `0xb14`: link down, 100M, full-duplex, bit8 plus raw bits9/11.
- `0xb18`: link down, 1000M, full-duplex, bit8 plus raw bits9/11.
- `0xb78`: link down, 1000M/full plus extra raw bits5/6 set.
- `0xb19`: exactly `0xb18 | bit0` = 1000M/full with MAC link latch asserted.

So the v91 `0xb14 -> 0xb78 -> 0xb19` path is a speed/PCS-status convergence sequence.  Bit2 alone is not required for bit0; it simply means the temporary decoded speed was 100M before the MAC settled to 1000M.
