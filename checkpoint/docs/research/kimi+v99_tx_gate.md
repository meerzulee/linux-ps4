# v99 — TX-dead / RX-alive: chip-design root-cause analysis

**kimi-k2.6, 2026-05-13**

## Observation

RX path works end-to-end (NAPI, descriptors, IRQ, host receives). TX path accepts descriptors into DMA memory, acknowledges the kick (`BAR+0x034 |= 4`), but the TX ring base (`BAR+0x03c`) never moves and no `TX_DONE` IRQ fires. Host sees complete electrical silence.

## Chip-design triage

| Option | Likelihood | Reasoning |
|---|---|---|
| **(b) MAC TX_EN bit missed** | **Highest** | RX proves DMA, IRQ, descriptor format, PHY link, and clock are all OK. The TX scheduler is a separate state machine inside the MAC that usually has its own enable bit (distinct from RX). A missing TX_EN bit means the kick is posted to a dead scheduler — descriptors sit untouched exactly as observed. Untouched BAR offsets `0x05c`, `0x070`, `0x080` are prime candidates. |
| **(a) TX FIFO not enabled** | High | Many MACs gate the TX engine until the TX FIFO passes a ready/self-test handshake. If the FIFO is held in reset or its ready flag is 0, the scheduler refuses to fetch descriptors to avoid underrun. This produces the same "stationary ring base" signature. |
| **(e) TX clock missing / wrong rate** | Medium | RX works, so the reference clock is present, but some MACs clock TX and RX domains separately. If a TX-specific PLL or divider is not programmed, the TX state machine never advances. Less likely because RX usually shares the same clock tree, but possible. |
| **(d) PAUSE / flow control** | Low | If the partner asserted PAUSE, the MAC would still fetch and queue descriptors; completions would simply be deferred. We see *zero* descriptor movement, not deferred movement. |
| **(f) RGMII direction / delay mismatch** | Low | A PHY-side sampling mismatch would cause CRC errors or runts at the host, not complete silence. The MAC would still consume descriptors and fire TX_DONE. |
| **(c) STP / 802.1x port block** | Negligible | No evidence of L2 switch logic in this MAC. |

## Conclusion

**Bet on (b) or (a).** The fact that RX works eliminates everything downstream of the MAC (PHY, cable, host). The fact that descriptors are written and kicked but never fetched eliminates everything upstream (driver, DMA mapping, descriptor format). The break is exactly at the TX scheduler gate inside the MAC.

## Next steps

1. **Read the untouched BAR range** `0x05c`, `0x060`, `0x064`, `0x06c`, `0x070`, `0x080` on a running Orbis system (or from Ghidra if the register map is documented) and diff against our values.
2. **Look for TX_EN or TX_FIFO_EN bits** in any register not yet written by `mts_mac_init` or `mts_parent_prelude`.
3. **Check `BAR+0x080`** specifically — many Marvell-derived MACs place FIFO / port-control registers in the `0x080-0x090` range.

If TX_EN is found, one register write unblocks the entire path.
