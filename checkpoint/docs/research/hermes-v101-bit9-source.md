# Hermes (gpt-5.5) — v101 BAR+0x06c bit9 source — 2026-05-13

Concrete answer: in the Orbis material I can verify, bit9 is not set by `mts_attach`, `mts_ifup`, `mts_init_rings_kick`, or the per-packet TX path.  The only known Orbis-derived software write that attempts to set it is the parent/MSK prelude sequence (`FUN_c85131d0` / sky2 hand-port):

```
BAR+0x60 = 0x00032100
BAR+0x64 = 0x00000006
BAR+0x68 = 0x00063b9c
BAR+0x6c = 0x00000300   // bits 8+9 requested
```

This is in our copied Orbis prelude patches (`0750-network-ps4-mts/0002`, lines 133-136; also sky2 quirk patch writes same sequence).  Your live result proves `0x6c[9]` is not a normal writable latch: software requests 0x300, hardware readback stays 0x100.

What does NOT set it: `mts_init_rings_kick` only writes descriptor bases and kicks (`0x44/0x3c/0x48/0x40/0x34/0x38/0x54`); `FUN_c85f1890` successful TX path only writes `BAR+0x34 |= 4`; `mts_attach` after `mts_mac_init` is newbus/resource setup, no 0x05c-0x300 BAR writes per prior audit.

Best classification: (a) hardware status / PLL-or-FIFO-ready consequence, not (b) a direct unlock write in MTS.  The strongest missing prerequisite is parent `msk_init_hw` outside the copied prelude, especially the documented `BAR+0x138: 2 -> 1` trigger (`deepseek+v100_baikal_tx_mechanism.md:14-29`).  That occurs in parent attach, not MTS open.  If bit9 is HW-set, test whether `0x138 2→1` makes `0x06c` read back 0x300 before TX kick.
