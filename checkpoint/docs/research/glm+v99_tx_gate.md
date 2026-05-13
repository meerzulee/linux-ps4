# v99: Why TX is dead — sky2 comparison reveals missing DMA prefetch + BMU init

## The problem

v98 confirmed: TX descriptors are correct in DMA memory (SOF|EOF|len, real buf
addr, OWN=0) but HW never flips OWN, BAR+0x03c never advances, no TX_DONE IRQ.
RX works fine via NAPI.

## sky2 (Yukon-2) TX pipeline: 3 independent stages must all be enabled

`sky2_up()` initialises TX in this order (drivers/net/ethernet/marvell/sky2.c):

1. **BMU init** (`sky2_qset`, line ~1079): writes `Q_CSR` with
   `BMU_CLR_RESET` (0x14) → `BMU_OPER_INIT` (0x23b = CLR_IRQ_PAR |
   CLR_IRQ_CHK | START | FIFO_ENA | OP_ON) → `BMU_FIFO_OP_ON` (0x80),
   then watermark `Q_WM = 0x600`.

2. **Prefetch unit init** (`sky2_prefetch_init`, line ~1088):
   `PREF_UNIT_CTRL = RST_SET` → `PREF_UNIT_CTRL = RST_CLR` → load
   `PREF_UNIT_ADDR_HI/LO` with DMA ring address → `PREF_UNIT_LAST_IDX`
   with ring_size−1 → `PREF_UNIT_CTRL = OP_ON` → readback flush.

3. **TX MAC FIFO** (line ~1010): `TX_GMF_CTRL_T = GMF_RST_CLR`,
   then `TX_GMF_CTRL_T = GMF_OPER_ON`.

4. **Doorbell** (`sky2_put_idx`, line ~1128):
   `wmb()` → write `PREF_UNIT_PUT_IDX` with `tx_prod`. This tells the
   prefetch unit "I've placed new descriptors, go fetch them."

If step 1 or 2 is skipped, the prefetch unit sits idle — descriptors are
in host memory but the hardware never reads them. That's exactly our symptom.

## Orbis msk_init_hw maps 1:1 onto sky2's 3-stage init

Decompiling FUN_c8511d50, the TX DMA init sequence is:

| BAR offset | Value | sky2 equivalent | Our driver? |
|---|---|---|---|
| 0x004 | 8 | (link/status init) | **NO** |
| 0x00c | 0 | MAC_CTRL2 full clear | **NO** (only bit 7) |
| 0x014 | 0 | MAC addr clear | **NO** |
| 0xe08 | 2 | BMU step (FIFO RST CLR?) | **NO** |
| 0xe18 | 2 → 1 | BMU step (FIFO OP ON?) | **NO** |
| 0xe80 | 1 | PREF_UNIT RST_SET | v91 YES |
| 0xe80 | 2 | PREF_UNIT RST_CLR | v91 YES |
| 0xe88 | tx_desc_lo | **PREF_UNIT_ADDR_LO** | **NO** |
| 0xe8c | tx_desc_hi | **PREF_UNIT_ADDR_HI** | **NO** |
| 0xe84 | 0x7ff | **PREF_UNIT_LAST_IDX** | **NO** |
| 0xe98 | 10 | (TX timer/watermark?) | **NO** |
| 0xe80 | 8 | **PREF_UNIT OP_ON** | v91 YES |

The 0xe80→0xe88→0xe84→0xe80 sequence matches sky2's PREF_UNIT init
structure exactly: reset, clear reset, program address+size, then enable.

**Our v91 writes 0xe80=1,2,8 but NEVER writes 0xe84/0xe88/0xe8c.**
The DMA engine turns on (OP_ON) without knowing the descriptor ring address
or size. It has nowhere to fetch from.

## Root cause

Two separate register banks for the TX descriptor ring address:

- **BAR+0x03c/0x044**: "simple" ring base pointer (what our driver writes)
- **BAR+0xe88/0xe8c**: DMA prefetch unit ring address (what msk_init_hw writes)

The prefetch unit at BAR+0xe80 uses ONLY 0xe88/0xe8c for its descriptor
fetch pointer, not 0x03c. Our driver writes to 0x03c but never to 0xe88/0xe8c.

Additionally, BAR+0xe84 (ring size mask = 0x7ff = 2047 entries) tells the
prefetch unit how many descriptors the ring has. Without it, the unit has
no idea where the ring wraps.

Finally, BAR+0xe08=2 and BAR+0xe18=2→1 are likely BMU FIFO init steps
(equivalent to sky2's Q_CSR BMU_CLR_RESET / BMU_OPER_INIT / BMU_FIFO_OP_ON).
We never write these either.

## Fix order (priority)

1. **Write BAR+0xe88/e8c** with tx_ring_dma before BAR+0xe80=8 (OP_ON).
   Proper sequence: e80=1 → e80=2 → e88=lo → e8c=hi → e84=0x7ff → e80=8.
2. **Write BAR+0xe84 = ring_size−1** (0xff for 256 entries) alongside e88/e8c.
3. **Write BAR+0xe08 = 2, BAR+0xe18 = 2 then 1** (BMU FIFO init, like sky2
   Q_CSR: CLR_RESET then OPER_INIT).
4. **Write BAR+0x004 = 8, BAR+0x00c = 0, BAR+0x014 = 0** (MAC init values
   from msk_init_hw — v90 already identified these).

## What about the kick?

sky2's doorbell is `PREF_UNIT_PUT_IDX` (offset 0x14 from the prefetch unit base).
Our BAR+0x034 |= 0x04 kick probably maps to this — it's a "poke the engine"
signal after descriptors are placed. But the kick is meaningless if the
engine was never told WHERE the descriptors live (0xe88/e8c) or HOW MANY
(0xe84). That's why bit 2 "sticks" — the engine can't process the kick
because its prefetch config is empty.

## The 0x05x–0x07x untouched registers

The v98 BAR dump showed non-zero values at 0x05c–0x070. These are likely
POR defaults for BMU FIFO thresholds or watermark registers — the hardware
set them at power-on. They don't need explicit init (sky2's BMU init sets
watermarks but they have reasonable defaults). The critical missing writes
are the explicit ones in msk_init_hw, not these passive registers.

## Summary

| Missing init | BAR | Consequence |
|---|---|---|
| Prefetch ring addr (lo) | 0xe88 | Engine can't find descriptors |
| Prefetch ring addr (hi) | 0xe8c | Engine can't find descriptors |
| Prefetch ring size | 0xe84 | Engine doesn't know ring length |
| BMU FIFO step 1 | 0xe08 | FIFO may stay in reset |
| BMU FIFO step 2 | 0xe18 | FIFO may stay in reset |
| MAC init values | 0x004/0x00c/0x014 | Stale state from POR |

The prefetch unit init (step 1–3) is the show-stopper. Without it, the
hardware has no path from host memory descriptors to its internal FIFO,
so TX descriptors sit unprocessed forever — exactly what v98 observed.