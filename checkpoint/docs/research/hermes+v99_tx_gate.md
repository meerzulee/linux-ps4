# Hermes (gpt-5.5) — v99 TX gate audit — 2026-05-13

Finding: I do NOT see a missing TX doorbell in the 0x05c-0x07c range.  The Orbis TX fetch trigger remains `BAR+0x34 |= 4` after enqueue (`FUN_c85f1890`, `/tmp/v93-ghidra/mts_tx_wrapper_FUN_c85f1890.c:29-44`).  `mts_init_rings_kick` programs TX base to BOTH `BAR+0x44` and `BAR+0x3c` from `softc+0x40`, then starts with `BAR+0x34 |= 1` (`mts_init_rings_kick.c:59-72,87-99`).  No Orbis path in the available decomp writes 0x05c/0x060/0x064/0x06c/0x070 as a per-open TX fetch enable; 0x060/0x064/0x06c are parent/prelude state and your dump already matches known sane values.

The register Orbis MUST hit before ring setup, and which is easy to miss, is `BAR+0x1c8`, not 0x05x-0x07x.  Prior `mts_ifup` decompile (`FUN_c85ec940`) shows:

```c
*(u32 *)(BAR+0x1c8) &= ~0x40;   // clear bit 6
mts_mac_init(sc);
mts_init_rings_kick(...);
```

Then `mts_init_rings_kick` immediately tests the same bit and returns without any ring/base/kick work if bit 6 is set (`mts_init_rings_kick.c:15-18`).  At the tail it writes `BAR+0x54=saved_mask`, clears softc transition, then sets `BAR+0x1c8 = (old & ~0x440) | 0x40` (`mts_init_rings_kick.c:115-123`).  So bit6 is a software/hardware gate around ring-init/fetch sequencing, not merely multicast bookkeeping.

For 0x05x-0x07x: Orbis-relevant writes are IRQ mask at 0x54, MAC pause 0x74, RX_GATE 0x78 bit0 clear, MAC_CLK 0x7c=25MHz.  None is TX-specific and RX works, so they are unlikely to explain TX-only no-fetch.

Recommended v99 experiment: in `ndo_open`, exactly bracket ring programming with `writel(readl(0x1c8)&~0x40, 0x1c8)` before base writes, then after both engines are started/kicked set `(readl(0x1c8)&~0x440)|0x40`; log 0x1c8 before/after.
