# deepseek-v41+v88_fallback_research.md — 2026-05-13

## Lead finding: MT7531 POR DSP defaults insufficient for link training; mainline mt7531_phy_config_init provides essential MMD and Token Ring writes that Orbis never does

Orbis targets Realtek RTL8211 PHYs.  Its efuse-gated C45 trim block (MMD
0x1e regs 0x174, 0x175, 0x172, etc.) and C22 page-0x52b5 magic pokes are
*Realtek-specific*.  On MT7531, the efuse check (`FUN_c8764760(0x6c) &
0x80800000`) fails → bulk of C45/TokRing skipped.  The remaining
unconditional C45/C22 tail targets registers that don't exist on MT7531
(MMD 0x1e regs 0x189, 0x122, 0x330; MMD 0x1f reg 0x268; MMD 7 reg 0x3c0).

**Net result:** MT7531 DSP runs at POR defaults, which are not tuned for
reliable 1000BT training on all cables/partners.  Training failure →
partner asserts Remote Fault (reg 5 bit 13) → AN cycling.

## (a) MT7531 vendor MMD writes — what mainline does that Orbis/we don't

Mainline `mt7531_phy_config_init` (`tmp/crashniels-6.15/drivers/net/phy/
mediatek/mtk-ge.c:76-97`) applies these register writes:

### MMD VEND1 (0x1e) writes — accessed via our SMI C45 (v86 already supports)

| Reg | Field | Mainline value | POR default | Effect if missing |
|-----|-------|---------------|-------------|-------------------|
| 0x123 | LPI_NORM_MSE_LO/HI_THRESH100 | 0xff / 0xff | ? (likely 0x00) | Tight signal-quality threshold rejects marginal link |
| 0x0a6 | MCC_NEARECHO_OFFSET (bits 15:8) | 0x3 | ? | Echo canceller may mis-detect near-end reflection as noise |
| 0x0c6 | DA_AD_BUF_BIAS_LP (bits 9:8) | 0x3 | ? | RX ADC bias suboptimal → distorted signal → training fail |
| 0x013 | TX_DELAY_PAIR_B (bits 10:8) | 0x4 | ? | RGMII skew on CPU port (not link-critical for user port) |
| 0x014 | TX_DELAY_PAIR_D (bits 2:0) | 0x4 | ? | RGMII skew on CPU port (not link-critical) |

### C22 page-extended writes — accessed via standard C22 (reg 0x1f page select)

| Page | Reg | Field | Mainline value |
|------|-----|-------|---------------|
| 0x0001 | 0x14 | EN_DOWNSHIFT (bit 4) | 1 (enable) |
| 0x52b5 | Token Ring ch=1,node=0xf,data=0x17 | SLAVE_DSP_READY_TIME (bits 22:15) | 0x5e |
| 0x0003 | 0x11 | POST_UPDATE_TIMER | 0x4b (mt7530 only) |

### Token Ring write protocol (from mtk-phy-lib.c:14-47)

```
// Select Token Ring page
write(C22 reg 0x1f, 0x52b5)

// Build TR command: bit15=1, bit13=0(write), bits11-10=ch, bits9-6=node, bits5-1=data_addr
tr_cmd = BIT(15) | ((ch&3)<<11) | ((node&0xf)<<7) | ((data_addr&0x3f)<<1)
write(C22 reg 0x10, tr_cmd)

// Write 32-bit data
write(C22 reg 0x11, tr_data & 0xffff)        // low 16 bits
write(C22 reg 0x12, (tr_data >> 16) & 0xffff) // high 16 bits

// Restore page
write(C22 reg 0x1f, 0)
```

**Critical TR write for v88:**
```
page = 0x52b5
tr_cmd = BIT(15) | (1<<11) | (0xf<<7) | (0x17<<1)  // = 0x8fae
         wait: ch=1 → bits 11-10 = 01 → (1<<10)???

Let me use the mtk-phy-lib formula:
ch=1, node=0xf, data=0x17
tr_cmd = BIT(15) | ((1&3)<<11) | ((0xf&0xf)<<7) | ((0x17&0x3f)<<1)
       = 0x8000 | (1<<11) | (15<<7) | (0x17<<1)
       = 0x8000 | 0x0800 | 0x0780 | 0x002e
       = 0x8fae
```

**But wait — Orbis already writes 0x8fae in block 6:**
```
write(0x10, 0x8fae)  // !! This is EXACTLY ch=1,node=0xf,data=0x17, WRITE mode
write(0x11, 0x0671)  // data low = 0x0671
write(0x12, 0x0006)  // data high = 0x0006
→ writes value 0x00060671 to SlvDPSready register (bits 22:15 = 0b0000_0011_0000_0011_1000_...)
```

**So Orbis DOES write to ch=1, node=0xf, data=0x17 via the accidental TR path!**
But the value is 0x00060671, not the 0x5e<<15 = 0x2f0000 that mainline writes.

Let me check: mainline writes `FIELD_PREP(SLAVE_DSP_READY_TIME_MASK, 0x5e)`.
`SLAVE_DSP_READY_TIME_MASK = GENMASK(22, 15)`.
`FIELD_PREP(GENMASK(22,15), 0x5e) = 0x5e << 15 = 0x2f0000`.

Orbis writes 0x00060671. Bits 22-15 of 0x00060671:
0x00060671 binary: ...0000 0110 0000 0110 0111 0001
Bits 22-15: 0000 0110 0 → 0x0c? Let me compute:
0x00060671 = 0b0000_0000_0000_0110_0000_0110_0111_0001
Bit positions (31...0):
31-24: 0000_0000
23: 0
22: 0
21: 0
20: 0
19: 0
18: 1
17: 1
16: 0
15: 0
14-8: 000_0110_0
7-0: 0111_0001

Bits 22-15: 0000_1100 = 0x0c = 12

So Orbis sets SlvDPSready time to 12 (0x0c), while mainline sets it to 94 (0x5e). 12 is a MUCH shorter DSP ready timeout than 94. This could cause DSP training to time out prematurely!

**This is a critical finding!** Orbis ACCIDENTALLY writes to the SlvDPSready TR register with a very short timeout (12 vs 94). This short timeout may cause the slave DSP to not complete its training before the master times out → training failure → Remote Fault.

## (b) RGMII TX/RX delay — NOT load-bearing for user port link

`MTK_PHY_GBE_MODE_TX_DELAY_SEL` (MMD 0x1e reg 0x13) and
`MTK_PHY_TEST_MODE_TX_DELAY_SEL` (MMD 0x1e reg 0x14) configure RGMII TX
clock delay on the **CPU port** (port 5/6 MAC↔Baikal MAC interface).  These
registers exist in the per-port PHY's MMD space but control the MAC-side
interface, not the PHY↔cable link.

- TX delay affects data integrity over RGMII once link is up
- Does NOT affect PHY cable-side link training or link establishment
- On MT7531 with internal PHYs (ports 0-4), the PHY↔MAC interface is
  internal digital, and TX delay is irrelevant for those ports

**TX/RX delay is NOT the blocker for link-up.**

## (c) Remote Fault as symptom of bad signal training

Chain of causation:
1. MT7531 POR DSP defaults are not optimized for all cables/partners
2. 1000BT training begins after AN completes
3. Master/slave DSP training sequence:
   a. Slave trains its timing recovery (~100ms)
   b. Slave trains its echo canceller (~400ms)
   c. Slave trains its FFE/DFE (~400ms)
   d. Master detects slave training complete → link UP
4. If SlvDPSready timeout is too short (Orbis wrote 0x0c = 12, mainline
   wants 0x5e = 94), the slave DSP may not finish training before the
   master declares failure
5. Master detects training timeout → drops link
6. Partner sees link drop → on next AN cycle, partner asserts RF in base
   page ("my link partner disappeared during training")
7. Our PHY sees RF → AN restarts → retry → fails again

This matches the observed cycling: AN complete (BMSR bit 5=1) → link never
up (BMSR bit 2=0) → partner sets RF (reg 5 bit 13=1) → AN restarts.

### Additional evidence: near-echo offset at POR

`MTK_PHY_MCC_CTRL_AND_TX_POWER_CTRL` (MMD 0x1e reg 0xa6) controls echo
cancellation.  The comment in mainline code: "If echo time is narrower
than 0x3, it will be regarded as noise."  Without this setting, the echo
canceller may reject legitimate reflected signals as noise, preventing
the DSP from converging during training.

## Three critical writes to apply in v88

All via existing SMI C45 (v86) or C22 — no new MDIO infrastructure needed.

### 1. Near-echo offset — MMD 0x1e reg 0xa6

```c
// MMD VEND1 (0x1e), reg 0xa6, set offset to 0x3
u16 val = smi_cl45_read(dev, 0x0a6001e);  // read current
val = (val & 0x00ff) | (0x03 << 8);        // bits 15:8 = 0x03
smi_cl45_write(dev, 0x0a6001e, val);
```

Equivalent to mainline:
```c
phy_modify_mmd(phydev, MDIO_MMD_VEND1, MTK_PHY_MCC_CTRL_AND_TX_POWER_CTRL,
               MTK_MCC_NEARECHO_OFFSET_MASK,
               FIELD_PREP(MTK_MCC_NEARECHO_OFFSET_MASK, 0x3));
```

### 2. 100M MSE threshold — MMD 0x1e reg 0x123

```c
// Set both lo and hi thresholds to 0xff (maximum = relaxed)
smi_cl45_write(dev, 0x0123001e, 0xffff);
```

Equivalent to mainline `phy_modify_mmd(... REG123, ..., 0xffff)`.

### 3. SlvDPSready time — Token Ring ch=1, node=0xf, data=0x17

Using C22 via the MT7531 extended page:

```c
u16 saved_page = smi_cl22_read(dev, 0x1f);

// Select Token Ring page
smi_cl22_write(dev, 0x1f, 0x52b5);

// Write TR command: ch=1, node=0xf, data=0x17, write mode
// tr_cmd = BIT(15) | ((1&3)<<11) | ((0xf&0xf)<<7) | ((0x17&0x3f)<<1) = 0x8fae
smi_cl22_write(dev, 0x10, 0x8fae);

// Write data: SlvDPSready = 0x5e in bits 22:15 (= 0x5e << 15 = 0x2f0000)
u32 tr_data = 0x5e << 15;  // = 0x002f0000
smi_cl22_write(dev, 0x11, tr_data & 0xffff);          // low = 0x0000
smi_cl22_write(dev, 0x12, (tr_data >> 16) & 0xffff);  // high = 0x002f

// Restore page
smi_cl22_write(dev, 0x1f, saved_page);
```

**CAUTION:** Orbis's accidental TR write (block 6) writes 0x8fae to reg
0x10 with data 0x00060671 — same command register, wrong value.  Our v88
write must go AFTER the Orbis replay, or we must read-modify-write to
preserve other bits in the SlvDPSready register.

### Safer: read-modify-write for SlvDPSready

```c
// Read current TR value
smi_cl22_write(dev, 0x1f, 0x52b5);
// tr_cmd for READ: BIT(15) | BIT(13) | ((1&3)<<11) | ((0xf&0xf)<<7) | ((0x17&0x3f)<<1)
// = 0xa000 | 0x0800 | 0x0780 | 0x002e = 0xafae
smi_cl22_write(dev, 0x10, 0xafae);  // READ ch=1,node=0xf,data=0x17
u16 tr_low = smi_cl22_read(dev, 0x11);
u16 tr_high = smi_cl22_read(dev, 0x12);
u32 current = ((u32)tr_high << 16) | tr_low;

// Modify bits 22:15 to 0x5e
current = (current & ~GENMASK(22,15)) | (0x5e << 15);

// Write back
smi_cl22_write(dev, 0x11, current & 0xffff);
smi_cl22_write(dev, 0x12, (current >> 16) & 0xffff);
smi_cl22_write(dev, 0x10, 0x8fae);  // WRITE ch=1,node=0xf,data=0x17

smi_cl22_write(dev, 0x1f, 0);  // restore page 0
```

## Recommended v88 experiment

Apply the three critical writes AFTER mts_mac_init replay and BEFORE AN
restart (or via phylib config_init).  Then restart AN.

Expected signal if hypothesis correct:
- BMSR bit 5 = 1 (AN complete) — same as before
- BMSR bit 2 = 1 (link UP) — NEW, within 2-5 seconds of AN start
- partner reg 5 = partner's base page WITHOUT Remote Fault (bit 13 = 0)
- BAR+0x04 = 0x00000b19 or similar with bit 0 set

If link still doesn't come up: also disable 1000BT advertisement (clear
reg 9 bit 9) to force 100TX fallback.  If 100TX works, the 1000BT DSP
path needs more tuning.  If 100TX also fails, the problem is more
fundamental (cable, partner, or PHY PMA power state).

--- deepseek-v41, 2026-05-13
