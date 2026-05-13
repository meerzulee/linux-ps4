# Hermes (gpt-5.5) — v97 RX-dead live audit — 2026-05-13

Main correction: BAR+0x38 is not proven RX.  Orbis `mts_init_rings_kick` writes both start pulses, but later `mts_intr` restarts TX by writing `BAR+0x34 |= 4` after `mts_tx_complete` (`mts_intr.c:244-260`) and restarts RX/refill by writing `BAR+0x38 |= 4` after RX bits `0x22` (`mts_intr.c:271-286`).  So 0x34=TX kick, 0x38=RX refill/kick is still consistent.  Bit 0 not sticking is probably normal: Orbis only ORs bit0 as a pulse (`mts_init_rings_kick.c:87-113`); readback bit3=0x8 likely means engine-running/status.

RX_AVAIL `0x00040040` but no descriptor OWN means the MAC sees packets, IRQ block works, but DMA is not completing into our RX ring.  Highest suspects: RX ring base/current pointer mismatch or descriptor visibility, not link/PHY.  Verify BAR+0x40/0x48 read back exact RX ring DMA low/high and that ring memory is coherent: Orbis programs RX base to both BAR+0x48 and BAR+0x40 from `softc+0x50` after initializing descriptors (`mts_init_rings_kick.c:37-58,73-85`).  Also confirm descriptors are initialized exactly `ctl=0x00000600`, `buf_lo=dma`, last `ctl|=0x40000000`, with wmb before BAR+0x38 kick.

`BAR+0x09c bit6` recovery is TX-error path only for status `0x00500000` (`mts_intr.c:64-147`): clear bit6, set bit6, free/reset all TX descriptors, zero TX producer state, memset TX ring, set each TX ctl `0x80000000` and aux0 `|=0xffff0000`, reprogram TX base BAR+0x44/0x3c, then `BAR+0x34 |= 1`.  It should not re-fetch RX descriptors.

Recommended live experiment: stop chasing 0x38 bit0 stickiness; dump BAR+0x40/0x48 vs RX dma_handle and first 4 RX descriptors before/after RX_AVAIL.
