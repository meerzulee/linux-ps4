# v90 MAC Link-Detector Research — Why BAR+0x04 bit 0 won't latch

**Date:** 2026-05-13  
**Status:** Complete research pass; actionable findings identified  
**Context:** v88 achieved 100% PHY-level health (RF=0, both receivers OK, AN-complete); BAR+0x04 bit 0 (link UP status) still reads 0x0000000b18, refusing to latch.

---

## Executive Summary

v88 and v89 experiments prove the **PHY is completely healthy at the wire level**:
- Partner's Remote Fault cleared (reg 5 bit 13 = 0)
- Master/Slave fault cleared (reg 10 bit 13 = 0)
- Both receivers report OK (reg 10 bits 11-10 = 0x3)
- Partner ACKs us (reg 5 bit 14 = 1)
- RGMII TX delays applied (mainline values: MMD 0x1e regs 0x13/0x14 = 0x0404)

**Yet the MAC's link detector** (BAR+0x04 bit 0) never transitions to 1. Aggressive userspace register experiments confirm that bit 0 is **purely hardware-driven**—writes are rejected or put the MAC into a degraded state.

After systematically reviewing **sky2.c (Marvell Yukon-2)**, **MTK mainline drivers**, **Orbis FW decompiles**, and all prior agent research, the blocker is a **MAC-side register we haven't yet identified**. The evidence points to **either**:

1. **A "link detector enable" or "PCS/PMA RX enable" gate bit** in the undiscovered BAR+0x080-0x0b4 range (occupied by unknown, auto-populated registers)
2. **An "RX/TX engine" enable bit** in BAR+0x208 or BAR+0x210 (both read as 0x00000001 with bit 0 set, never written by us)
3. **A "host port forwarding" enable** that requires switch management frames (but glm's v87 research shows these run AFTER link-up, not before)

---

## Key Findings

### 1. Sky2 Baikal Quirk Writes (doesn't help, but is instructive)

**File:** `/home/meerzulee/Work/ps4/linux-ps4/src/6.x-baikal/drivers/net/ethernet/marvell/sky2.c`  
**Lines:** 3234-3326 (in `sky2_reset()`)

The PS4 Linux sky2 patch includes Aeolia/Baikal-specific register setup:

```c
if (pdev->vendor == PCI_VENDOR_ID_SONY &&
    (pdev->device == PCI_DEVICE_ID_SONY_AEOLIA_GBE ||
     pdev->device == PCI_DEVICE_ID_SONY_BAIKAL_GBE)) {
    sky2_write32(hw, 0x60, 0x32100);   // PRELUDE reg (parent, not BAR0)
    sky2_write32(hw, 0x64, 6);         // PRELUDE reg
    sky2_write32(hw, 0x68, 0x63b9c);   // PRELUDE reg
    sky2_write32(hw, 0x6c, 0x300);     // PRELUDE reg
    val1 = sky2_read32(hw, 0x158);     // PRELUDE reg (BAR+0x158, clock latch)
    val2 = sky2_read32(hw, 0x160);     // PRELUDE reg
    val1 &= ~0x33333333;
    val2 &= ~0xCC00000;
    sky2_write32(hw, 0x158, val1);
    sky2_write32(hw, 0x160, val2);
}
```

**Important:** These writes are to **parent-prelude registers** (0x60, 0x64, 0x68, 0x6c, 0x158, 0x160), not to the Baikal MTS MAC's BAR+0x000-0x3ff space. We already replicate these in `mts_mac_init()` (BAR+0x158 clock latch). **These are NOT the missing link.**

### 2. Undiscovered BAR Offsets That Read Non-Zero

From **v89 hardware experiments** (checkpoint/docs/research/2026-05-13-v89-result.md):

| BAR+offset | Read value | Observations |
|---|---|---|
| 0x080 | 0x000002bb | **populated, unknown** |
| 0x098 | 0x00000002 | **populated, unknown** |
| 0x09c | 0x0000006f | MTS_PKT_ENGINE_CTRL (our define, never written) |
| 0x0b0 | 0x001f03ff | **bitmask shape, unknown** |
| 0x0b4 | 0x001fffff | **bitmask shape, unknown** |
| 0x100 | 0x00000017 | **status register or counter** |
| 0x110 | 0x0000004a | **counter-like** |
| 0x118 | 0x000000a7 | **counter-like** |
| 0x128 | 0x00000080 | **populated, unknown** |
| **0x208** | **0x00000001** | **⚠️ BIT 0 SET — never written by driver** |
| **0x210** | **0x00000001** | **⚠️ BIT 0 SET — never written by driver** |

**Most suspicious:** BAR+0x208 and BAR+0x210 both have **only bit 0 set to 1**, and we've never written to them. They may be:
- **RX engine running / TX engine running status mirrors** (read-only flags)
- **IRQ sub-block enable gates** that need explicit 0→1 write
- **TX/RX data path gates** that block the PHY's link signal from latching into BAR+0x04

### 3. Sky2 Doesn't Reveal MAC Link Detector Mechanism

Searched sky2.c for any register patterns matching 0x208, 0x210, 0x080, etc. — **found none**. Sky2's register offset names are all in the GM_* (MAC port registers) family:
- `GM_TX_CTRL = 0x0008`
- `GM_RX_CTRL = 0x000c`
- `GM_GP_STAT = 0x0000`, `GM_GP_CTRL = 0x0004`

These are 16-bit MAC port registers (not 32-bit BAR offsets). Yukon-2's architecture may differ significantly from Baikal's MTS MAC. **Sky2 doesn't help us here.**

### 4. MTK Mainline Drivers (mt7531_phy_config_init, mt7530.c)

Searched `/tmp/vanilla-6.15.4/drivers/net/phy/mediatek/` and `/drivers/net/dsa/mt7530.c` for any "host port enable" or "MAC link enable" register writes. **Found none.** The DSA driver (for switch port configuration) does NOT configure the MT7531's *internal* PHY registers or the Baikal MAC's link detection.

The MT7531 PHY itself is configured via MDIO MMD writes (which v88 and v89 already cover). There is **no separate "host port link enable"** register in the MT7531 PHY space.

### 5. Orbis FW Decompile Evidence (from prior agent research)

From **glm-5.1+v87_link_research.md** and **deepseek-v41+v87_link_research.md**:

**Q1 — PMA/PCS enable:** Orbis does NOT write to MMD 1 (PMA/PMD) or MMD 3 (PCS). The PHY's PMA/PCS are left in default powered-on state. **No MMD 1/3 writes needed.**

**Q5 — In-band switch management:** Runs AFTER link-up via ethertype 0xfa42 management frames, NOT before. Does not block initial link establishment.

**Q6 — BAR+0x04 force-link:** Orbis NEVER writes BAR+0x04 bit 0 (is hardware-driven only).

**Conclusion:** Orbis's `gbe:phy_ctrl` and `gbe:ctrl` threads do NOT write to any MAC register that would "gate" the link detector. They only:
1. Configure PHY via MDIO (C22/C45)
2. Poll BAR+0x04 bit 0 waiting for link
3. If link appears, send management frames to switch
4. Gate RX IRQ (BAR+0x54 &= ~0x1000)

Orbis never pre-gates a "MAC link enable" register.

---

## Hypothesis: Missing MAC-Side Gate Bit

Given:
- PHY is 100% healthy (confirmed by v88/v89)
- BAR+0x04 bit 0 is purely hardware-driven (userspace writes rejected)
- Aggressive random writes to entire BAR don't help (v88 EXP 1-14)
- No PHY-side fix remains (RGMII delay done, DSP corrections done)

**The MAC must have a hidden enable bit that blocks the link signal from reaching BAR+0x04.**

Candidates:

#### Candidate A: BAR+0x208 or BAR+0x210 (RX/TX engine enable)

Both read as 0x00000001 (bit 0 set) and are never written. On other MACs (Lantiq GSWIP, Microchip KSZ, etc.), there are typically **RX_CTRL** and **TX_CTRL** registers that gate the data path. If bit 0 of these registers gates "RX engine enabled" or "TX engine enabled," then **writing 0x00000001 to them might be a no-op** (already set), **or we need to write a different pattern.**

**Action to test (v91):**
```c
// Try writing 0x00000003 (two bit enable) or 0x00000005 (different pattern)
writel(0x00000003, bar + 0x208);  // RX engine enable?
writel(0x00000003, bar + 0x210);  // TX engine enable?
// Then read BAR+0x04 to see if link latches
```

#### Candidate B: BAR+0x0b0 or BAR+0x0b4 (MAC control or gating mask)

Both have bitmask-shaped values (0x001f03ff, 0x001fffff). These could be:
- **IRQ routing masks** (which IRQs reach the CPU?)
- **Port enable masks** (which ports are active?)
- **MAC feature gates** (RX before link? timestamp enable?)

On Lantiq GSWIP, register 0x905 + (port × 0xC) controls frame length checks and other per-port MAC features. BAR+0x0b0/0x0b4 might be similar.

**Action to test (v91):**
```c
// Try clearing all bits, then re-reading BAR+0x04
writel(0, bar + 0x0b0);
writel(0, bar + 0x0b4);
msleep(10);
// See if link detector disables (expected) or if link suddenly appears
```

#### Candidate C: BAR+0x080, 0x098, 0x128 (undocumented MAC enable registers)

These are populated but unknown. They could be **per-port MAC enable registers**, **interface mode selectors**, or **PCS/PMA gating**. Without Baikal datasheet or Orbis source, we can only guess.

**Action to test (v91):**
```c
// Read Orbis's state at these offsets
// Log: "BAR+0x080 = 0x%08x, BAR+0x098 = 0x%08x, ..."
// Then try writing the exact Orbis values back
```

---

## What We Know Orbis Does (and doesn't do)

### ✅ Orbis DOES write:

From **mts_mac_init** decompile in our ps4_mts.c:

1. **BAR+0x00 (MTS_SMI_CMD)** — MDIO commands
2. **BAR+0x08 (MAC_CTRL1)** — OR with 0x07597c00
3. **BAR+0x0c (MAC_CTRL2)** — AND with ~0x80
4. **BAR+0x10 (MAC_CTRL3)** — AND with 0xffffff6e, OR with 0x81
5. **BAR+0x30 (MAC_MODE)** — = 0x00010100
6. **BAR+0x34 (RX_KICK)** — = 0x1 (start RX engine?)
7. **BAR+0x38 (TX_KICK)** — = 0x1 (start TX engine?)
8. **BAR+0x74 (MAC_PAUSE)** — = 0x00002277
9. **BAR+0x78 (RX_GATE)** — AND with ~1
10. **BAR+0x7c (MAC_CLK)** — = 25000000
11. **BAR+0xac (INIT_AC)** — = 9
12. **BAR+0x200 (MASTER_RESET)** — = 0
13. **BAR+0x204 (IRQ_ENABLE_FULL)** — = 0x10001388
14. **BAR+0x54 (IRQ_MASK)** — = 0x007bbffe

**None of these are BAR+0x208, 0x210, 0x080, 0x0b0, 0x0b4, 0x098, etc.**

### ❌ Orbis does NOT write:

- Any register in 0x080-0x0ff range
- Any register in 0x100-0x1ff range (except 0x200, 0x204)
- BAR+0x208, 0x210 (never touched)
- BAR+0x34/0x38 (RX_KICK, TX_KICK) — but we do in v84

**Wait.** Let me check: does Orbis write BAR+0x34 (RX_KICK) or 0x38 (TX_KICK) at all?

From glm/deepseek decompiles: **Orbis does NOT write these.** The MAC's engines are started by setting specific bits in MAC_CTRL registers, not by "kicking" them at 0x34/0x38.

---

## Actionable Next Steps (v90/v91)

### Priority 1: Determine if BAR+0x208/0x210 are write-gates

These registers have **only bit 0 set** and are in the **descriptor queue area** (0x03c-0x048 are descriptor pointers; 0x200+ are control). They might be:
- **Engine enable/status** (0x208 = RX engine status, 0x210 = TX engine status)
- **Queue valid flags** (bit 0 = "this queue has valid descriptors")

**Test sequence for v90:**
```c
// After mts_mac_init and before link poll

// Try writing 0x00000001 (already set, probably no-op)
writel(0x00000001, bar + 0x208);
writel(0x00000001, bar + 0x210);

// Try writing 0x00000003 (two-bit enable pattern)
writel(0x00000003, bar + 0x208);
writel(0x00000003, bar + 0x210);

// Try writing 0x000000ff (wide enable pattern)
writel(0x000000ff, bar + 0x208);
writel(0x000000ff, bar + 0x210);

// After each write, read BAR+0x04 and log if bit 0 changed
```

### Priority 2: Check if BAR+0x0b0/0x0b4 gate data path

These are **enable/mask registers** (bitmask-shaped values). They might gate:
- Which ports are active
- Which interrupts reach the CPU
- Which data paths are enabled

**Test sequence for v90:**
```c
// Try setting different bit patterns
writel(0xffffffff, bar + 0x0b0);  // enable all bits
writel(0xffffffff, bar + 0x0b4);  // enable all bits

// Then read BAR+0x04 to see if link latches
```

### Priority 3: Capture Orbis's full register state

If we can run the Orbis kernel on target hardware, **capture all BAR0 register values at the exact moment link comes up**. This would tell us:
- Which registers transition when link latches
- What values are required

**File to add to `uefi_mts_diag.c` or `ps4_mts.c` v90:**
```c
// After link comes up, dump entire BAR0
for (offset = 0; offset < 512; offset += 4) {
    u32 val = readl(bar + offset);
    if (offset % 16 == 0)
        printk("\n");
    printk("[0x%03x]=0x%08x ", offset, val);
}
```

This baseline would eliminate guesswork.

### Priority 4: Test Phase 2 (TX/RX descriptor rings)

If the MAC needs "live" TX/RX rings to declare link (chicken-egg problem), then:
1. Set up minimal descriptor rings with valid pointers
2. Install dummy TX/RX buffers
3. Maybe send a single TX frame
4. Check if BAR+0x04 bit 0 latches

This requires ~200 LOC but is a fallback if register-gate theory fails.

---

## Register Reference (Summary)

### Definitely do NOT write:
- BAR+0x04 (link status — hardware-driven, writes rejected)
- BAR+0x34, 0x38 (RX/TX kick — not Orbis pattern; engines start via MAC_CTRL bits)

### Already writing correctly:
- BAR+0x08, 0x0c, 0x10 (MAC_CTRL1/2/3)
- BAR+0x30 (MAC_MODE)
- BAR+0x74, 0x78, 0x7c (MAC_PAUSE, RX_GATE, MAC_CLK)
- BAR+0x200, 0x204, 0x54 (master reset, IRQ blocks)

### Unknown but suspect (candidate gates):
- **BAR+0x208** — RX engine enable? (currently 0x00000001)
- **BAR+0x210** — TX engine enable? (currently 0x00000001)
- **BAR+0x0b0** — MAC/port enable mask? (currently 0x001f03ff)
- **BAR+0x0b4** — IRQ routing mask? (currently 0x001fffff)
- **BAR+0x080** — undocumented MAC enable (currently 0x000002bb)
- **BAR+0x098** — undocumented MAC enable (currently 0x00000002)

---

## Conclusion

The v88 PHY-level fix is **100% validated**. The remaining link-latch blocker is a **MAC-side register gate we haven't identified**. 

**Best leads:** BAR+0x208 or BAR+0x210 (RX/TX engine enable), based on:
1. Both are in descriptor/engine control area
2. Both have only bit 0 set (suggest "enable" semantics)
3. We've never written them
4. Other Ethernet MACs have similar "engine enable" gates

**Fallback:** If register gates don't work, implement Phase 2 (TX/RX rings) and try to send a packet. Some embedded MACs require at least a dummy packet to declare link.

**Final note:** Without Baikal datasheet or Orbis source, we're working by analogy. The solution likely exists in existing Linux drivers (sky2, MTK, Lantiq) — just need to map Baikal's register space to the right conceptual block.

