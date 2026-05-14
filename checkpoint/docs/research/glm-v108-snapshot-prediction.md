# v108: Orbis BAR0 snapshot prediction (staked)

## Methodology

Prediction based on: (1) all Ghidra decompilations of mts_mac_init, msk_init_hw, mts_ifup, gbe:ctrl; (2) v97-v106 live BAR dumps from the Linux driver; (3) register-by-register diff of what Orbis writes vs what our driver writes.

## Q1: Specific offsets where Orbis BAR0 will differ from our v97 state

| Offset | Our v97 value | Predicted Orbis value | Why it differs |
|--------|--------------|----------------------|----------------|
| 0x004 | 0x00000b18 | 0x00000b19 | bit 0 = link UP latched (Orbis has working TX, link confirmed) |
| 0x008 | 0x00000XXX | 0x0759XXXX | mts_mac_init ORs 0x7597c00 into this register; we never touch it |
| 0x06c | 0x00000100 | 0x00000300 | bit 9 = TX DMA ready HW status, auto-set when link bit 0 latches |
| 0x030 | POR default | 0x00010100 | mts_mac_init writes 0x10100 (frame config); we never write it |
| 0x074 | POR default (~0x0000XXXX) | 0x00002277 | mts_mac_init writes 0x2277 (TX watermark); we never write it |
| 0x07c | POR default (~0x0000XXXX) | 0x017D7840 | mts_mac_init writes 25MHz (0x17D7840); we never write it |
| 0x1c8 | 0x00a00000 | 0xc0a00000 | bits 30+31 set by DA filter loop; our driver skips the loop |
| 0x078 | ~POR | same OR bit 0 cleared | mts_mac_init does &= ~1 on 0x078; we never touch it |

**Most likely to be the smoking gun**: 0x1c8 (DA filter accept-all masks), 0x074 (TX watermark), or 0x030 (frame config). One of these three is the gate that enables the MAC link-status evaluation path.

## Q2: Predicted values at key offsets

```
Offset  Our v97      Orbis prediction  Confidence
------  ----------   ---------------  ----------
0x004   0x00000b18   0x00000b19      HIGH - bit 0 must be set if link UP
0x008   0x00000XXX   0x07XXXXXX      MEDIUM - OR of 0x7597c00 depends on POR value
0x06c   0x00000100   0x00000300      HIGH - bit 9 must follow bit 0 of 0x004
0x030   unknown      0x00010100      HIGH - explicit write in mts_mac_init
0x074   unknown      0x00002277      HIGH - explicit write in mts_mac_init
0x078   unknown      (POR & ~1)      LOW - just clears bit 0
0x07c   unknown      0x017D7840      HIGH - explicit write of 25MHz divisor
0x1c8   0x00a00000   0xc0a00000      HIGH - DA filter bits 30+31 must be set
```

There will also be differences in the 0x100-0x200 range (multicast hash filter programmed by mts_mac_init's DA loop, MAC address registers at 0x014/0x018, and VLAN filter regs at 0x140/0x144), but those are cosmetic.

## Q3: If diff is ONLY 0x004 bit 0 and 0x06c bit 9

If the ONLY differences are status bits (0x004.0 and 0x06c.9), this proves:

1. **All driver-writeable control registers are correct**. Our init sequence produces identical register state to Orbis for every register we write.
2. **The latch is a pure hardware status signal** that depends on some internal state machine timing we can't control from software.
3. **The root cause is timing or sequencing**, not missing register writes. The latch window opens and closes during a specific microsecond window in the MAC's internal PCS/RGMII state machine, and we're not hitting it.
4. This would point to: (a) the MAC needs to see a PHY RGMII transition while the MAC clock/reset state is in a specific phase, or (b) there's an internal PLL lock that needs to settle during engine start, or (c) the 0xe8x status unit DOES exist on Baikal but needs different programming than we tried.

## Q4: If diff includes a register we've NEVER written

**Most likely offset: 0x074 (TX FIFO watermark = 0x2277)**.

Reasoning: The v98 live BAR dump showed non-zero values at 0x05c-0x070 that are POR defaults. mts_mac_init writes 0x2277 to 0x074 — a TX FIFO watermark register analogous to sky2's Q_WM. This is the only mts_mac_init write in the 0x05x-0x07x range that we've never attempted. If it's not 0x2277 on Orbis, it means the POR default is sufficient, but if it IS 0x2277, it's a write we're missing that gates the TX DMA FIFO.

Second candidate: 0x030 = 0x10100 (TX/RX frame config). This register is written immediately before the DA filter gate check in mts_mac_init, and we've never written it.

## Skin in the game

If the Orbis dump shows:
- **0x1c8 = 0xc0a00000**: I'm right that the DA filter accept-all masks are the missing gate. Fix: `writel(0xc0a00000, bar + 0x1c8)` in ndo_open after mac_init.
- **0x074 = 0x2277**: I'm right that TX watermark is required. Fix: add to mac_init or ndo_open.
- **0x074 = POR default (not 0x2277)**: Okay, watermark was set by something else or POR is fine.
- **0x030 = 0x10100**: Confirmed frame config is needed. Fix: add to mac_init.
- **BOTH 0x1c8 differs AND 0x074/0x030/0x07c differs**: Multiple missing writes. Need all of them.
- **Diff is ONLY 0x004.0 and 0x06c.9 (pure status)**: Timing/sequencing problem, not missing registers. Need to investigate clock/reset ordering or the status unit.