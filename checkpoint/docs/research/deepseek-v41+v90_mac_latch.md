# deepseek-v41+v90_mac_latch.md — 2026-05-13

**Primary finding: BAR+0x208=1 and BAR+0x210=1 are hardware self-set status
bits signifying MAC engine readiness — they are NOT software-initialised by
any Orbis function.  The MAC side needs the GMAC serial interface (PCS/GMII)
properly clocked and in the correct RGMII mode for the PHY's link signal to
propagate to BAR+0x04 bit 0.  Orbis sets up this clock+mode implicitly via
BAR+0x030=0x10100 and BAR+0x07c=25MHz, but there may be additional PCS/gate
registers in the 0x080–0x0c0 range that we never write.**

## Q1 — BAR offsets auto-set but never written by us

I decompiled every Orbis function that touches BAR registers: `mts_mac_init`
(`0xffffffffc85ecb60`), `mts_init_rings_kick` (`0xffffffffc85ef1b0`),
`mts_ifup` (`0xffffffffc85ec940`), `msk_init_hw` (`0xffffffffc8511d50`),
`FUN_c85131d0` (parent prelude), `mts_intr` (`0xffffffffc85edcf0`).

### Complete BAR write audit of mts_mac_init (in execution order)

| Step | BAR offset | Write | Notes |
|------|-----------|-------|-------|
| 1 | 0x200 | 0 | Master reset clear |
| 2 | 0x050 | W1C (read then re-write) | Ack pending IRQs |
| 3 | 0x0ac | 9 | Unknown init constant |
| 4 | 0x07c | 25000000 | MAC clock reference = 25 MHz |
| 5 | 0x078 | `val & ~1` | Clear bit 0 = enable RX gate |
| 6 | 0x014 | MAC addr [0:3] byte-swapped | Primary MAC low |
| 7 | 0x018 | MAC addr [4:5] byte-swapped | Primary MAC high |
| 8 | 0x140 | Secondary MAC + bit31 (if sec-MAC enabled) | Secondary MAC low |
| 9 | 0x144 | Secondary MAC [4:5] (if sec-MAC enabled) | Secondary MAC high |
| 10 | 0x00c | `val & 0xffffff7f` | MAC_CTRL2: clear bit 7 |
| 11 | 0x074 | 0x2277 | MAC_PAUSE |
| 12 | 0x008 | `val \| 0x07597C00` | MAC_CTRL1: set 9 feature bits |
| 13 | 0x1d4 | 1 | Unknown register |
| 14 | 0x010 | `(val & 0xffffff6e) \| 0x81` | MAC_CTRL3 |
| 15 | 0x030 | 0x10100 | MAC_MODE |
| 16 | 0x1c4 | 1→0→1→0 (per hash entry) | MCAST_HASH_CTRL toggles |
| 17 | 0x1bc | hash data (per entry) | MCAST_HASH_DATA |
| 18 | 0x1c0 | `index \| 0x80` | MCAST_HASH_IDX + commit |
| 19 | 0x1c4 | 3 | End multicast hash: broadcast accept |
| 20 | 0x1c8 | `val \| 0xc0000000` | MCAST_HASH_MASK: promisc bits |

### BAR writes in mts_init_rings_kick (executed after mts_mac_init by mts_ifup)

| Step | BAR offset | Write | Notes |
|------|-----------|-------|-------|
| 21 | 0x044 | `softc+0x40` (TX desc hi) | TX descriptor DMA addr hi |
| 22 | 0x03c | `softc+0x40` (TX desc lo) | TX descriptor DMA addr lo |
| 23 | 0x048 | `softc+0x50` (RX desc hi) | RX descriptor DMA addr hi |
| 24 | 0x040 | `softc+0x50` (RX desc lo) | RX descriptor DMA addr lo |
| 25 | 0x034 | `val \| 1` | **RX engine start** (bit 0 set) |
| 26 | 0x038 | `val \| 1` | **TX engine start** (bit 0 set) |
| 27 | 0x054 | `softc+0x3098` (saved IRQ mask) | IRQ mask restore |

### BAR writes in FUN_c85131d0 (parent prelude, called from msk_init_hw)

| Step | BAR offset | Write | Notes |
|------|-----------|-------|-------|
| P1 | 0xf10 | 1, then 2 | Unknown (switch-link signal?) |
| P2 | 0xf04 | 1, delay 12ms, =2 | Switch GPIO reset |
| P3 | 0x060 | 0x32100 (if PCIe MPS=0x10000) | PCIe timing |
| P4 | 0x064 | 6 or 0x4000006 | PCIe timing |
| P5 | 0x068 | 0x63b9c (if PCIe MPS=0x10000) | PCIe timing |
| P6 | 0x06c | 0x300 or 0 | PCIe timing |
| P7 | 0x120 | 1 | Unknown |
| P8 | 0x11c | `val & 0xf8ff` | Unknown (clears bits 8-9?) |

### None of these writes touch BAR+0x208 or BAR+0x210

These registers are **hardware self-set**.  They are NOT written by any
software path in the Orbis init sequence.  They most likely reflect the MAC
engine's internal state:

- `BAR+0x208 = 0x00000001`: MAC TX engine "ready" flag (bit 0 = ready)
- `BAR+0x210 = 0x00000001`: MAC RX engine "ready" flag (bit 0 = ready)

These get set by hardware after the MAC completes its internal state-machine
initialisation.  Our writes to BAR+0x034 (RX start) and BAR+0x038 (TX start)
should trigger the same hardware self-set.  If they don't, the engine-start
sequence is incomplete.

### The 0x080–0x0bf mystery range

| Offset | Value on live PS4 | Interpretation |
|--------|------------------|----------------|
| 0x080 | 0x000002bb | GMAC PCS status? bits 0,1,3,4,5,7,9 set |
| 0x098 | 0x00000002 | Counter or status flag |
| 0x09c | 0x0000006f | PKT_ENGINE_CTRL (bit 6 toggled on MAC error) |
| 0x0b0 | 0x001f03ff | Filter mask? bits 0-9 set, bit 20-24 set |
| 0x0b4 | 0x001fffff | Filter mask? bits 0-20 set |

**BAR+0x09c** is the only one Orbis touches — `mts_intr` toggles bit 6
during packet-engine error recovery (when BAR+0x50 bit 0x500000 fires):

```c
// From mts_intr (0xffffffffc85edcf0), error recovery for bit 0x500000:
uVar5 = in(BAR+0x09c);
uVar5 = uVar5 & 0xffffffbf;  // clear bit 6  (= PKT_ENG_RESET begin)
out(BAR+0x09c, uVar5);
uVar5 = in(BAR+0x09c);
uVar5 = uVar5 | 0x40;        // set bit 6   (= PKT_ENG_RESET release)
out(BAR+0x09c, uVar5);
// then: drain TX ring, reload TX_DESC_BASE, kick RX restart
```

The **initial value** 0x6f = binary 0b01101111 comes from hardware POR.
Bits 0-3 and 5-6 set at POR.  Bit layout:
- Bit 0 = PKT_ENG_TX_EN?
- Bit 1 = PKT_ENG_RX_EN?
- Bit 2 = RX_FIFO_EN?
- Bit 3 = TX_FIFO_EN?
- Bit 5 = LINK_MONITOR_EN?  ← candidate for link-latch gate
- Bit 6 = PKT_ENG_RESET (active-low: 0=reset, 1=normal)

If bit 5 of BAR+0x09c controls the link monitor, POR sets it to 1 (enabled).
Our problem would be if something clears it.  Since we don't write 0x09c, it
should stay at POR value.

## Q2 — Trace the link-latch path in Orbis

The link-latch chain in Orbis is **entirely hardware-driven**, no software
gate.  Evidence:

1. `mts_link_change` (`0xffffffffc85eeb90`) only **reads** BAR+0x04,
   never writes it.  It's pure status decode.

2. `mts_intr` handles IRQ bit 0x4 (link change) by calling
   `mts_link_change()`.  It does NOT enable any link-detection register.

3. `gbe:phy_ctrl` (event 0x1) reads BAR+0x04 bit 0 to check link state.
   If link DOWN, it restarts AN — again, no MAC-side register write.

4. `gbe:ctrl` init (`FUN_c85f1e80`) polls BAR+0x04 bit 0 in a 70×100ms
   loop waiting for link to come up.  No MAC-side link-enable register.

**The MAC silicon must independently detect the PHY's link signal and
set BAR+0x04 bit 0.**  For this to work, the MAC must:
a. Have its GMAC receive path enabled and clocked
b. Be in the correct interface mode (GMII/RGMII) to decode the PHY signal
c. Have its link-monitor state machine enabled

## Q3 — PCS/sync and interface mode analysis

### MAC_MODE (BAR+0x030 = 0x10100)

`0x10100 = 0b0001_0000_0001_0000_0000`
- Bit 8 = 1: **GMAC serial mode = GMII?** (vs MII/ROMII/RGMII)
- Bit 16 = 1: **MAC RX path enable / link-monitor enable?**

In Yukon-2, `GM_SERIAL_MODE` at port offset 0x10 controls the serial
interface (MII/GMII).  Bits select the operating speed and mode.
On Baikal, BAR+0x030 is the equivalent.  0x10100 with bits 8 and 16 set
likely configures the MAC for GMII mode with link detection enabled.

If this mode doesn't match the PHY's output interface:
- PHY outputs RGMII, MAC expects GMII → signals misinterpreted → link
  never detected
- PHY outputs GMII, MAC expects RGMII → same problem

The MT7531 CPU port (port 5 or 6) typically outputs RGMII.  If the Baikal
MAC is configured for GMII (bit 8), there's a mismatch.

**Hypothesis:** BAR+0x030 bit 8=1 might need to be 0 for RGMII mode.
Our v89 added RGMII TX delay on the PHY side (MMD 0x1e regs 0x13/0x14),
but the MAC side might still be in GMII mode.

### GMAC clock (BAR+0x07c = 25 MHz)

Orbis writes `25000000` (0x017D7840) to BAR+0x07c.  For RGMII, the MAC
clock reference should be 125 MHz (for 1000BT) or 25 MHz (for 100BT/10BT).
The GMII mode uses 125 MHz for 1000BT.  If the clock is wrong, the MAC
won't sample PHY signals correctly.

25 MHz is correct for 100BT GMII but wrong for 1000BT (needs 125 MHz).
At 100BT with AN, the PHY should drive RX_CLK at 25 MHz, which the MAC
samples with its 25 MHz clock.  This should work.

### BAR+0x118 / 0x128 / 0x12c — auto-incrementing counters

```
0x118 = 0x000000a7 = 167 decimal
0x128 = 0x00000080 = 128 decimal
0x12c = 0x00000096 = 150 decimal
```

These look like RX PCS sync counters:
- 0x118: RX symbol errors or invalid code-groups counted
- 0x128: RX sync events or comma-detect events
- 0x12c: RX idle events or link-pulse events

The non-zero values suggest the MAC IS receiving something from the PHY.
If the MAC were completely deaf, these would be 0.  The GMII/RGMII
interface IS active — the MAC is seeing symbols from the PHY.

**This means the physical interface IS working.**  The MAC just isn't
latching the link-up condition at BAR+0x04 bit 0.

## Q4 — What we missed from Orbis init

### Already replicated (v87/v88/v89)

All 27 BAR writes from mts_mac_init + mts_init_rings_kick + parent prelude:
✅ BAR+0x200=0, 0x050=W1C, 0x0ac=9, 0x07c=25M, 0x078=clear b0
✅ BAR+0x014/0x018 MAC addr, 0x00c=clear b7, 0x074=0x2277, 0x008=OR 0x7597C00
✅ BAR+0x1d4=1, 0x010=MAC_CTRL3, 0x030=0x10100, multicast hash
✅ BAR+0x044/0x03c/0x048/0x040 descriptor addrs
✅ BAR+0x034|=1 RX start, 0x038|=1 TX start, 0x054 IRQ mask
✅ Parent prelude: 0xf10/f04/0x060/0x064/0x068/0x06c/0x120/0x11c
✅ PHY: SlvDPSready=0x5e, near-echo=0x3, MSE threshold=0xff, TX delay=0x4

### NOT replicated

**Nothing from mts_mac_init itself** — we have all 20 BAR writes.  The
only potential gap is **execution ORDER** — we replay writes in the listed
order, but are all of them taking effect correctly?  Specifically:

1. **BAR+0x078 clear bit 0** opens RX gate — must come AFTER other MAC
   register configs.  We do this.

2. **BAR+0x034 bit 0** (RX start from mts_init_rings_kick) — must happen
   AFTER BAR+0x030 (MAC_MODE).  We do this.

3. **Multicast hash setup** writes 0x1bc→0x1c0→0x1c4→0x1c0|0x80→0x1d0
   in a specific tight loop with timeout polling of 0x1d0 bit 0.  If our
   multicast hash loop gets the hash data or polling wrong, the MAC might
   hang in hash-write state and not enter operational mode.

## Q5 — TX chicken-and-egg: NOT required

`FUN_c85f1e80` (gbe:ctrl init) confirms: the first frame is sent ONLY
after BAR+0x04 bit 0 reads 1 (link is UP).  The poll loop waits up to
7 seconds for link.  If link never comes up, TX never starts.

TX path needs working link, not the other way around.  **Q5 = dead end.**

## The core hypothesis: MAC in GMII mode, PHY outputs RGMII

BAR+0x030 = 0x10100 with bit 8=1 suggests **GMII mode**.  The MT7531
CPU port typically uses **RGMII**.  In GMII mode, the MAC expects:
- 8-bit parallel RXD[7:0] with RX_DV and RX_CLK separately
- RX_CLK at 125 MHz for 1000BT, 25 MHz for 100BT

In RGMII mode, the PHY outputs 4-bit RXD[3:0] with RX_DV on a shared
pin (RGMII RX_CTL), and RX_CLK at half rate (62.5 MHz for 1000BT,
12.5 MHz for 100BT).  GMII vs RGMII decode is fundamentally different.

If the MAC is in GMII mode and the PHY outputs RGMII, the MAC:
- Sees RXD[7:0] with wrong bit positions and timing
- RX_DV is misinterpreted
- The MAC sees garbage but might still count "symbol events" (explaining
  non-zero counters at 0x118/0x128/0x12c)
- Link detection logic never triggers → BAR+0x04 bit 0 stays 0

**This matches ALL symptoms:** symbols flowing, non-zero counters, no
link latch.

### Fix hypothesis

Change BAR+0x030 mode bits.  Possible values:
- 0x10100 → GMII mode (current Orbis setting)
- 0x00100 or 0x10000 → RGMII mode (try alternate bits)

Or check if there's a separate MAC interface mode register in the
0x080-0x0bf range that overrides BAR+0x030.

## Recommended v90 experiment

Read back BAR+0x030 and BAR+0x080 before and after kexec to verify the
mode value.  Then try:
1. `BAR+0x030 = 0x00100` (clear bit 8, keep bit 16) — RGMII mode
2. `BAR+0x030 = 0x10000` (keep bit 16 only)
3. If neither works, check BAR+0x080 bit layout for a separate RGMII
   mode select bit.

Also: read BAR+0x118/0x128/0x12c periodically after AN completes to
confirm counters increment (proving the MAC sees PHY symbols).

--- deepseek-v41, 2026-05-13
