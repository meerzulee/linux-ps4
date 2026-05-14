# v100: mts_mac_init BAR register writes in 0x05c-0x07c and 0x100+ ranges

## Key finding: no DMA address written to 0x05c-0x07c or 0x100+

Decompiled `mts_mac_init` (0xffffffffc85ecb60). BAR writes in the
ranges of interest:

### 0x05c-0x07c range
| Offset | Value | Notes |
|---|---|---|
| 0x050 | read-then-write-back (RMW) | likely interrupt/status mask |
| 0x074 | 0x2277 | TX threshold / watermark register |
| 0x078 | read, clear bit 0 | gate disable? |
| 0x07c | 25000000 (0x17D7840) | CLOCK_DIV or timer register |

**0x074 = 0x2277** is especially interesting - this is a TX FIFO
watermark/threshold register never written by our driver. In sky2,
`Q_WM = 0x600` (BMU watermark) and `Q_AL` (almost-empty level) are
required before the BMU/FIFO will accept descriptors. Our driver
never writes 0x074.

**0x07c = 0x17D7840** (25 MHz clock divider) is also never written
by our driver. Could be a timer for TX completion polling.

### 0x100+ range
| Offset | Value | Notes |
|---|---|---|
| 0x140 | MAC addr lo (0x80000000 | swapped bytes) | VLAN/MAC filter |
| 0x144 | MAC addr hi (swapped) | VLAN/MAC filter |
| 0x1bc | hash entry (per-iter) | multicast hash |
| 0x1c0 | hash index (per-iter) | multicast hash |
| 0x1c4 | 1,0,1,3 (cmd strobe) | multicast hash ctrl |
| 0x1c8 | hash length config | multicast hash mask |
| 0x1d4 | 1 | unknown enable |
| 0x200 | 0 | clear at start of mts_mac_init |

**No DMA-address-like values (0x01XXXXXX pattern) appear in 0x100-0x200.**

### Other key writes from mts_mac_init
| Offset | Value | Notes |
|---|---|---|
| 0x004 | RMW: clear bits, keep link status | already noted |
| 0x008 | OR 0x7597c00 | INT mask / MAC config |
| 0x00c | clear bit 7, clear bit 4, set bit 0 | MAC_CTRL2 bits |
| 0x010 | RMW: clear bits 0x91, set bits 0x81 | MAC config |
| 0x014 | swapped MAC address bytes 0-3 | MAC addr lo |
| 0x018 | swapped MAC address bytes 4-5 | MAC addr hi |
| 0x030 | 0x10100 | TX/RX frame config |
| 0x0ac | 9 | PHY LED/timer |

### Critical: 0x074 and 0x07c never written by our driver

- **BAR+0x074 = 0x2277**: TX watermark. sky2 writes Q_WM (watermark)
  before enabling the prefetch unit. Without this, the TX BMU may refuse
  to accept descriptors because its FIFO threshold is at POR default (0).
  Our live BAR dump shows 0x070 = 0x00010003, but not 0x074 because
  our driver never writes it.

- **BAR+0x07c = 25MHz**: Likely clock divisor for inter-packet gap or
  TX completion timer. Not strictly needed for DMA fetch but could
  affect completion interrupt generation.

### The gbe:ctrl thread (FUN_c85f1e80) writes

After `mts_init_rings_kick`, the gbe:ctrl thread does:
- **BAR+0x080 |= 1** (byte write) — if VLAN tag mode active
- Writes MAC management frame (ethertype 0xFA42) via TX path
- **BAR+0x054 &= ~0x1000** — clear PHY IRQ gate after link UP

BAR+0x080 shows 0x000002bb in our live dump. This register is never
written by our driver either.

## Hypothesis update

The TX prefetch unit on Baikal is NOT at 0xe80-0xe8c (that range is
unresponsive on real hardware). The actual TX DMA init must use the
lower BAR range. Suspects:

1. **BAR+0x074 = 0x2277** — TX FIFO watermark (analogous to sky2 Q_WM)
2. **BAR+0x03c + 0x044** — paired TX desc base (already written, but
   could need 0x074 watermark first)
3. **BAR+0x030 = 0x10100** — frame config (TX/RX size enable bits)
4. **BAR+0x07c** — 25MHz clock divisor

Most likely fix: write 0x074=0x2277 and 0x07c=0x17D7840 before
enabling the TX engine. The watermark register gates the BMU FIFO
which gates the prefetch unit.