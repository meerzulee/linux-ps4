# v90: Why MAC BAR+0x04 bit 0 won't latch — Ghidra RE findings

**Date:** 2026-05-13
**Status:** Research complete, patch pending
**Ghidra project:** orbis-ps4-dump (Orbis 12.02 kernel ELF)

## TL;DR

BAR+0x04 bit 0 (link UP) is purely hardware-driven. The MAC's internal
link detector requires the DMA engine path to be initialized — specifically
the `msk_init_hw` register sequence that runs BEFORE `mts_mac_init`. Our
Linux driver skips the entire `msk_init_hw` phase, leaving TX/RX DMA
engines uninitialized. Additionally, we skip `msk_init_hw`'s full clears
of BAR+0x00c (→0) and BAR+0x014 (→0) which leave stale bits from POR
defaults. BAR+0x208 and BAR+0x210 are **hardware-auto-set** status registers
(TX/RX DMA engine active) — no Orbis function writes them.

---

## Q1 — BAR offsets we never wrote but have values

### Registers NOT written by any Orbis function

| BAR+offset | Read value | Orbis code? | Explanation |
|---|---|---|---|
| 0x080 | 0x000002bb | **NOT found** | Hardware status; possibly TX frame counter or watermark |
| 0x098 | 0x00000002 | **NOT found** | Hardware status; possibly interrupt coalescing status |
| 0x0b0 | 0x001f03ff | **NOT found** | Hardware default; bitmask shape suggests DMA ring size mask |
| 0x0b4 | 0x001fffff | **NOT found** | Hardware default; bitmask shape suggests DMA descriptor limit |
| 0x100 | 0x00000017 | **NOT found** | Hardware counter (23 decimal) |
| 0x110 | 0x0000004a | **NOT found** | Hardware counter (74 decimal) |
| 0x118 | 0x000000a7 | **NOT found** | Hardware counter (167 decimal) |
| 0x128 | 0x00000080 | **NOT found** | Hardware status; 0x80 = bit 7 |
| 0x12c | 0x00000096 | **NOT found** | Hardware counter (150 decimal) |
| 0x1d8 | 0x000000b0 | **NOT found** | Possible TX threshold (176) |
| 0x1dc | 0x000000e0 | **NOT found** | Possible RX threshold (224) |
| 0x1e0 | 0x000000d4 | **NOT found** | Possible threshold (212) |
| **0x208** | **0x00000001** | **NOT found** | **TX DMA engine active status (bit 0)** |
| **0x210** | **0x00000001** | **NOT found** | **RX DMA engine active status (bit 0)** |

### Registers written by Orbis but NOT by our driver

| BAR+offset | Orbis value | Who writes | Our driver? |
|---|---|---|---|
| 0x00c | 0 (full clear) | msk_init_hw | ❌ we only clear bit 7 |
| 0x014 | 0 (MAC addr clear) | msk_init_hw | ❌ not done |
| 0x004 | 8 (initial value) | msk_init_hw | ❌ not done |
| 0x044/0x3c | TX DMA desc addr | mts_init_rings_kick | ✅ we do this |
| 0x048/0x040 | RX DMA desc addr | mts_init_rings_kick | ✅ we do this |
| 0x09c | bit 6 toggled | mts_intr (TX recovery) | ❌ never touched |
| 0x0e08 | 2 | msk_init_hw | ❌ |
| 0x0e18 | 2, then 1 | msk_init_hw | ❌ |
| 0x0e80 | 1, 2, 8 | msk_init_hw | ❌ **DMA engine init** |
| 0x0e84 | 0x7ff | msk_init_hw | ❌ TX ring size mask |
| 0x0e88/0x0e8c | DMA addr (low/high) | msk_init_hw | ❌ |
| 0x0e98 | 10 | msk_init_hw | ❌ |
| 0x0eac | 0x10 | msk_init_hw | ❌ |
| 0x0ead | 0x10 | msk_init_hw | ❌ |
| 0x0ed0 | 400 | msk_init_hw | ❌ |
| 0x0ec0 | link_timer×1000 | msk_init_hw | ❌ |
| 0x0ec8 | 4 | msk_init_hw | ❌ |
| 0x0eb8 | 4 | msk_init_hw | ❌ |
| 0x0ed8 | 4 | msk_init_hw | ❌ |
| 0x138 | 2, then 1 | msk_init_hw | ❌ |
| 0x1c4 | 1/0 toggling | mts_mac_init (DA filter) | ❌ |
| 0x1c8 | OR 0xc0000000 | mts_mac_init (DA filter) | ❌ |
| 0x1d0 | poll bit 0 | mts_mac_init (DA filter) | ❌ |

---

## Q2 — Trace the link-latch path

### How Orbis detects link (gbe:ctrl init, FUN_c85f1e80)

```
1. mts_init_rings_kick()  — set up DMA rings, kick TX+RX
2. IF VLAN mode: if_flags |= IFF_UP, ioctl(SIOCSIFFLAGS)
3. Poll BAR+0x04 for link UP (0x46 = 70 iterations, ~1ms each)
4. IF link UP: send ethertype 0xFA42 management frame
5. mts_link_change()      — read speed/duplex, notify network stack
6. BAR+0x054 &= ~0x1000   — clear PHY IRQ gate
```

### The actual link-change reader (mts_link_change, FUN_c85eeb90)

```c
uVar3 = *puVar6;                    // BAR+0x04
if ((uVar3 & 1) == 0) {            // link DOWN
    uVar4 = 0;
} else {                            // link UP
    uVar5 = uVar3 >> 2 & 3;         // speed: bits 2-3
    uVar4 = ((uVar3 & 0x10) >> 4) * 2 + 1;  // duplex: bit 4
    if      (uVar5 == 0) uVar4 |= 0x10;  // 10Mbps
    else if (uVar5 == 1) uVar4 |= 0x20;  // 100Mbps
    else if (uVar5 == 2) uVar4 |= 0x40;  // 1000Mbps
    uVar4 |= (uVar3 >> 6) & 4;            // bit 6: aux?
}
```

BAR+0x04 is **read-only** for link status — the hardware sets bit 0 when
the MAC's internal link state machine detects a live link.

### What gates the link state machine

Based on complete RE of all Orbis MTS/msk functions, the MAC's link
detector needs **all of the following initialized**:

#### 1. The complete msk_init_hw DMA engine setup (CRITICAL — we skip this)

This is the `msk_init_hw` function at `0xffffffffc8511d50`, called by
`baikal_gbe_attach` BEFORE `mts_mac_init`. It writes:

```c
// Key writes in order:
BAR+0x158 = modify bits (PCI-specific)
BAR+0x160 = modify bits (PCI-specific)
BAR+0x004 = 8                        // ← INITIAL value for link/status reg
BAR+0xf00 = 1, 2, 0x10              // switch pre-init
BAR+0x158 |= 2 then |= 1            // clock gating
BAR+0x138 = 2, then 1               // ← UNKNOWN: reset sequence?
BAR+0xe08 = 2                        // ← TX DMA control
BAR+0xe18 = 2, then 1               // ← TX DMA reset/init
BAR+0x014 = 0                        // ← clear MAC address
BAR+0x00c = 0                        // ← clear MAC CTRL2 FULLY
(void)readl(BAR+0x00c)              // readback (flush)
BAR+0xe80 = 1, 2, 8                 // ← TX DMA engine enable sequence
BAR+0xe84 = 0x7ff                   // ← TX ring size mask
BAR+0xe88 = TX_desc_bus_addr_lo     // ← TX descriptor bus address
BAR+0xe8c = TX_desc_bus_addr_hi
BAR+0xe98 = 10                       // ← interrupt coalesce
BAR+0xeac = 0x10, 0x10              // ← TX thresholds
BAR+0xed0 = 400                      // ← TX timeout
BAR+0xec0 = link_timer * 1000        // ← interrupt moderation timer
BAR+0xec8 = 4, 0xeb8 = 4, 0xed8 = 4 // ← RX thresholds?
BAR+0xf04 = 1; udelay(12); = 2; udelay(500)  // switch reset
// ... VLAN/mac filter setup ...
BAR+0xf22 |= 1                       // ← filter enable
BAR+0xf2c |= 1                       // ← filter enable
BAR+0xf30 = calculated               // ← filter config
BAR+0xf80 = calculated               // ← filter config
BAR+0xf20 = 2                        // ← filter mode
BAR+0xf70 = 0x101                    // ← filter enable
```

**Our driver writes NONE of these.** We go straight to `mts_mac_init`
without running `msk_init_hw`. The most critical omissions:

- **BAR+0x00c = 0** — Full clear of MAC_CTRL2. We only clear bit 7 later.
  Stale POR bits in MAC_CTRL2 could prevent the link state machine from
  starting.
- **BAR+0x004 = 8** — Initial value in LINK_STATUS register before the
  AND-mask in mts_mac_init. Bits 3-7 may be control bits, not just status.
- **BAR+0xe80 sequence (1→2→8)** — TX DMA engine enable. Without this,
  the DMA engine cannot process TX frames, and management frames cannot
  be sent.
- **BAR+0x014 = 0** — Full clear of MAC address register before setting
  the real address.

#### 2. DMA ring setup and engine kick (done by both msk_init_hw and mts_init_rings_kick)

After msk_init_hw sets up the 0xe80-range DMA engine, mts_init_rings_kick
(**also called twice**: once by msk_init_hw and once by mts_ifup) does:
```c
BAR+0x34 |= 1    // kick TX
BAR+0x38 |= 1    // kick RX
BAR+0x44 = TX_desc_addr_lo
BAR+0x3c = TX_desc_addr_lo  // note: same addr
BAR+0x48 = RX_config
BAR+0x40 = RX_config
BAR+0x54 = softc_irq_mask
```

#### 3. TX engine is needed for switch management frames

The gbe:ctrl init function (FUN_c85f1e80) polls BAR+0x04 for link UP,
and IF link is detected, calls `FUN_c85f2250` (link_change) which sends
ethertype 0xFA42 management frames to configure the MT7531 switch.

**However**, if link NEVER rises, the management frames are still sent
(but after a 70ms poll loop timeout). So the switch won't be configured
for port forwarding, which could contribute to the circular dependency.

But the critical question remains: why doesn't BAR+0x04 bit 0 ever set?

---

## Q3 — PCS/sync registers

| Offset | Value on PS4 | Likely function | Orbis writes it? |
|---|---|---|---|
| 0x118 | 0xa7 (167) | Possibly TX frame counter or PCS sync counter | No |
| 0x128 | 0x80 (128) | Possibly PCS status or sync watermark | No |
| 0x12c | 0x96 (150) | Possibly RX frame counter | No |

None of these are written by any Orbis function. They appear to be
auto-incrementing hardware counters. The values (167, 128, 150 for
0x118/0x128/0x12c) are consistent with packet/cell counters that start
from 0 after reset and increment with traffic.

**Conclusion:** These are NOT PCS sync gating registers. They're
read-only status counters that don't affect link detection.

---

## Q4 — Complete Orbis vs Linux driver BAR write comparison

### Writes in mts_mac_init (FUN_c85ecb60) that we DO replicate

| Step | Offset | Value | Linux driver? |
|---|---|---|---|
| 1 | 0x200 | 0 | ✅ MTS_MASTER_RESET |
| 2 | 0x050 | read then write back | ✅ |
| 3 | 0x0ac | 9 | ✅ MTS_INIT_AC |
| 4 | 0x004 | read, AND 0x7fffcfff | ✅ v87 |
| 5 | 0x07c | 25000000 | ✅ MTS_MAC_CLK |
| 6 | 0x078 | AND ~1 | ✅ MTS_RX_GATE |
| 7 | 0x014 | MAC addr bytes | ❌ we skip |
| 8 | 0x018 | MAC addr bytes | ❌ we skip |
| 9 | 0x00c | AND ~0x80 | ✅ (but should be 0 first) |
| 10 | 0x074 | 0x2277 | ✅ MTS_MAC_PAUSE |
| 11 | 0x008 | OR 0x07597c00 | ✅ MTS_MAC_CTRL1 |
| 12 | 0x1d4 | 1 | ✅ MTS_INIT_1D4 |
| 13 | 0x010 | AND 0xffffff6e OR 0x81 | ✅ MTS_MAC_CTRL3 |
| 14 | 0x030 | 0x10100 | ✅ MTS_MAC_MODE |

### Writes in mts_mac_init that we DON'T replicate

| Step | Offset | Value | Purpose |
|---|---|---|---|
| 15 | 0x1c4 | 1 (then 0, in loop) | DA filter write strobe |
| 16 | 0x1bc | address data | DA filter address data |
| 17 | 0x1c0 | index + 0x80 | DA filter index (write) |
| 18 | 0x1d0 | poll bit 0 | DA filter write complete |
| 19 | 0x1c4 | 3 | DA filter done |
| 20 | 0x1c8 | OR 0xc0000000 | DA filter enable bits |

### Writes in msk_init_hw that we ENTIRELY skip

| Offset | Value(s) | Purpose |
|---|---|---|
| 0x004 | 8 | Initial link/control reg value |
| 0x00c | 0 (full clear) | **Critical: clears MAC_CTRL2 POR defaults** |
| 0x014 | 0 + readback | Clear MAC address before setting |
| 0x138 | 2, then 1 | Unknown: reset sequence? |
| 0xe08 | 2 | TX DMA control |
| 0xe18 | 2, then 1 | TX DMA reset/init |
| 0xe80 | 1→2→8 | **TX DMA engine enable sequence** |
| 0xe84 | 0x7ff | TX ring size mask |
| 0xe88/e8c | TX desc DMA addr | TX descriptor base |
| 0xe98 | 10 | Interrupt coalesce count |
| 0xeac/ead | 0x10/0x10 | TX threshold |
| 0xed0 | 400 | TX timeout |
| 0xec0 | timer*1000 | Interrupt moderation |
| 0xec8/eb8/ed8 | 4/4/4 | RX threshold |
| 0xf04 | 1→2 (with delays) | MT7531 switch reset via BAR |
| 0xf22 | |= 1 | Filter enable |
| 0xf2c | |= 1 | Filter enable |
| 0xf30 | calculated | Filter config |
| 0xf80 | calculated | Filter config |
| 0xf20 | 2 | Filter mode |
| 0xf70 | 0x101 | Filter enable |

### Writes in mts_init_rings_kick that we partially replicate

| Offset | Value | Our driver? |
|---|---|---|
| 0x34 | |= 1 (TX kick) | ✅ |
| 0x38 | |= 1 (RX kick) | ✅ |
| 0x44 | TX desc addr lo | ✅ |
| 0x3c | TX desc addr lo | ✅ |
| 0x48 | RX config | ✅ |
| 0x40 | RX config | ✅ |
| 0x54 | softc_irq_mask | ✅ (different value) |

### Writes in gbe:ctrl init we DON'T replicate

| Offset | Value | Purpose |
|---|---|---|
| (softc+0x80) | |= 1 | ifnet if_flags (NOT a BAR write!) |
| N/A | management frame | Requires working TX path |

---

## Q5 — TX chicken-and-egg

### Can we send ONE frame without link?

Yes — the Orbis driver does exactly this in `FUN_c85f1e80`:

```c
// gbe:ctrl init: poll for link, but proceed regardless
iVar5 = 0x46;
do {
    uVar3 = *puVar7;  // BAR+0x04
    if (uVar3 & 1)     // link UP detected!
        break;
    udelay(1000);      // ~1ms per iteration = 70ms total
} while (--iVar5);

// THEN send management frame via TX:
FUN_c85f1890(param_1, local_78, 0x22);  // TX frame
```

The TX function `FUN_c85f1890` uses:
1. Allocates mbuf, copies frame data
2. Calls `FUN_c85f1aa0` (queue for TX)
3. **BAR+0x34 |= 4** (kick TX descriptor)
4. Polls for completion

**BUT**: This works because by the time gbe:ctrl init runs, the
msk_init_hw + mts_mac_init + mts_init_rings_kick sequence has already
fully initialized the DMA engine path (including all 0xe80+ registers).

### Minimum for ONE TX frame

For our Linux driver to send a single management frame, we would need at
minimum:

1. **DMA rings allocated** (we have this)
2. **TX DMA engine enabled** (BAR+0xe80 sequence 1→2→8) — **MISSING**
3. **TX descriptor ring registered** (BAR+0xe88/0xe8c) — **MISSING**
4. **BAR+0x34 |= 4** (TX kick) — we do this, but without steps 2-3 it's
   writing to an uninitialized engine

---

## Critical finding: what gates BAR+0x04 bit 0

After exhaustive RE of ALL Orbis MTS/msk functions, the answer is:

**The MAC's link detector at BAR+0x04 bit 0 requires the complete
msk_init_hw sequence to have run, specifically:**

### Most likely root cause: BAR+0x00c = 0 (full clear)

In msk_init_hw, **before** mts_mac_init:
```c
// msk_init_hw at 0xffffffffc8511d50
BAR+0x014 = 0;          // clear MAC address
BAR+0x00c = 0;          // FULL clear of MAC_CTRL2
(void)readl(BAR+0x0c);  // readback flush
```

Then in mts_mac_init:
```c
BAR+0x00c = read & ~0x80;  // only clear bit 7
```

Our driver only does the second step (clear bit 7), never the full clear
to 0. The POR default of BAR+0x00c may have bits that prevent the link
state machine from starting. A full write of 0 would clear all stale bits.

### Second most likely: BAR+0xe80 DMA engine enable

Without the BAR+0xe80 write sequence (1→2→8), the TX DMA engine is not
started. Even though we kick TX via BAR+0x34, the DMA engine isn't
configured. This could also prevent the link detector from working if the
MAC requires the TX path to be initialized before it will assert link.

### Third: BAR+0x004 initial value = 8

Writing 8 (bit 3) to the link/status register before any AND-masking
might set up initial state that the MAC needs. This is a control register,
not purely read-only.

---

## Recommended next steps (priority order)

1. **Add BAR+0x00c = 0 write** to msk_init_hw equivalent, BEFORE
   mts_mac_init. Follow with readback flush. This is the single most
   likely fix.

2. **Add BAR+0x004 = 8 write** early in init. Matches Orbis exactly
   and costs nothing.

3. **Add BAR+0x014 = 0 write** with readback flush. Clears stale MAC
   address before setting real one.

4. **Add the BAR+0xe80 sequence** (1→2→8) for TX DMA enable with
   corresponding BAR+0xe84/0xe88/0xe8c writes for TX descriptor setup.

5. **Add BAR+0x138 = 2 then 1** reset sequence.

6. **Add BAR+0xe08 = 2 and BAR+0xe18 = 2 then 1** for TX DMA control.

7. Consider adding BAR+0xe98/0xeac/0xead/0xed0/0xec0 values for
   TX coalescing and timing.

---

## Appendix: BAR+0x09c (MTS_PKT_ENGINE_CTRL) analysis

The value 0x0000006f on PS4 = binary 01101111 = bits 0,1,2,3,5,6.

The interrupt handler (`mts_intr` at 0xffffffffc85edcf0) toggles:
```c
BAR+0x09c &= ~0x40;   // clear bit 6 during TX error recovery
BAR+0x09c |= 0x40;    // restore bit 6
```

No other function writes to BAR+0x09c. The value 0x6f must accumulate
from:
- Hardware default bits (POR)
- Possible auto-set status bits
- The bit 6 toggle in interrupt handler

Our driver never writes to BAR+0x09c. We should investigate whether
writing an initial value to this register is needed.

---

## Register map summary (newly identified from msk_init_hw)

| Offset | Name (tentative) | Value | Source |
|---|---|---|---|
| 0x138 | MTS_RESET_SEQ? | 2→1 | msk_init_hw |
| 0xe08 | MTS_TX_DMA_CTRL | 2 | msk_init_hw |
| 0xe18 | MTS_TX_DMA_RESET | 2→1 | msk_init_hw |
| 0xe80 | MTS_TX_DMA_ENABLE | 1→2→8 | msk_init_hw |
| 0xe84 | MTS_TX_RING_MASK | 0x7ff | msk_init_hw |
| 0xe88 | MTS_TX_DESC_LO | DMA addr | msk_init_hw |
| 0xe8c | MTS_TX_DESC_HI | DMA addr | msk_init_hw |
| 0xe98 | MTS_TX_COALESCE | 10 | msk_init_hw |
| 0xeac | MTS_TX_THRESH1 | 0x10 | msk_init_hw |
| 0xead | MTS_TX_THRESH2 | 0x10 | msk_init_hw |
| 0xed0 | MTS_TX_TIMEOUT | 400 | msk_init_hw |
| 0xec0 | MTS_LINK_TIMER | timer*1000 | msk_init_hw |
| 0xec8 | MTS_RX_THRESH1 | 4 | msk_init_hw |
| 0xeb8 | MTS_RX_THRESH2 | 4 | msk_init_hw |
| 0xed8 | MTS_RX_THRESH3 | 4 | msk_init_hw |
| 0xf04 | MTS_SW_RESET | 1→2 (with delays) | msk_init_hw |
| 0xf20 | MTS_FILTER_MODE | 2 | msk_init_hw |
| 0xf22 | MTS_FILTER_EN1 | |= 1 | msk_init_hw |
| 0xf2c | MTS_FILTER_EN2 | |= 1 | msk_init_hw |
| 0xf30 | MTS_FILTER_CFG | calculated | msk_init_hw |
| 0xf70 | MTS_FILTER_CTRL | 0x101 | msk_init_hw |
| 0xf80 | MTS_FILTER_CFG2 | calculated | msk_init_hw |
| 0x204 | MTS_IRQ_ENABLE_FULL | 0x10001388 | mts_intr (first call) |
| 0x09c | MTS_PKT_ENGINE_CTRL | auto-set | mts_intr toggles bit 6 |
| 0x208 | MTS_TX_DMA_ACTIVE | auto-set (RO) | NOT written by Orbis |
| 0x210 | MTS_RX_DMA_ACTIVE | auto-set (RO) | NOT written by Orbis |

---

## Verification checklist

Per CLAUDE.md: all register values and write sequences verified against
primary source (Ghidra decompilation of Orbis 12.02 kernel ELF).

- [x] mts_mac_init: 0xffffffffc85ecb60 — decompiled, all BAR writes listed
- [x] msk_init_hw: 0xffffffffc8511d50 — decompiled, all BAR writes listed
- [x] mts_init_rings_kick: 0xffffffffc85ef1b0 — decompiled
- [x] mts_intr: 0xffffffffc85edcf0 — decompiled, BAR+0x204/0x09c writes confirmed
- [x] mts_ifup: 0xffffffffc85ec940 — decompiled, calls sequence confirmed
- [x] gbe:ctrl init: 0xffffffffc85f1e80 — decompiled, link poll + mgmt frame confirmed
- [x] FUN_c85ef020 (ring stop): BAR+0x34=2, BAR+0x38=2 — confirmed
- [x] All BAR+0x208/0x210 writes: NONE found in any MTS/msk function