# v92: MT7531 TX Enable — Mainline Registers We Have NOT Written

**Date:** 2026-05-13
**Context:** PHY link handshake is healthy (BMSR=0x7969, LP=0xc5e1, RF=0) but
RTL8153 USB-Eth partner reports NO-CARRIER, meaning PHY TX is not actually
transmitting on the wire.  Question: what does mainline do to enable the
MT7531 PHY TX output that our v88/v89 driver misses?

**Sources verified:** tmp/vanilla-6.15.4 `drivers/net/phy/mediatek/mtk-ge.c`,
`drivers/net/dsa/mt7530.c`, `drivers/net/dsa/mt7530.h`,
`drivers/net/phy/mediatek/mtk-phy-lib.c`, `drivers/net/phy/mediatek/mtk.h`

---

## Executive Summary

**The mainline `mt7531_phy_config_init` (mtk-ge.c) is a PHY-level init only.
It does NOT contain a "TX enable" register — the MT7531's TX line driver
is always powered on by default after BMCR reset with AN enabled.** The PHY
doesn't have a separate "TX power-down" or "output enable" bit that needs
clearing like some Realtek PHYs do.

The real architecture is different from what we assumed:

1. **Mainline mtk-ge.c** — standalone PHY driver. Only 6 register writes:
   SlvDPSready, near-echo, RX ADC bias, 100M MSE thresholds, TX delay,
   downshift enable. **None of these enable TX — they tune DSP parameters.**

2. **Mainline mt7530.c DSA driver** — switch management. This does the
   CRITICAL work: **switch port force-link-up via PMCR register**,
   **CORE PLL enable via MMD VEND2 reg 0x403**, and
   **RGMII clock/delay setup via CLKGEN_CTRL**. These are switch-side
   operations, NOT PHY-side MDIO registers.

3. **On PS4, there is NO DSA switch driver.** The MT7531 is behind the
   Sony MTS MAC, not managed by Linux's DSA subsystem. The MTS MAC
   talks to port 5 (or an internal PHY port) via in-band management
   frames (ethertype 0xFA42). The Orbis firmware configures the switch
   ports via these management frames, NOT via MDIO.

**Conclusion: the missing "TX enable" is not a PHY register at all — it's
the SWITCH PORT CONFIGURATION that the DSA driver normally does. On PS4,
the Orbis `gbe:ctrl` thread sends management frames to set switch ports
to forwarding state. Without those frames, the switch port stays in
ISOLATED/BLOCKING state and doesn't forward TX frames to the wire.**

However, the PHY itself should still transmit AN FLP bursts regardless
of switch state. If the partner sees NO-CARRIER at all, there may be
a deeper MAC-side issue (from v90: missing BAR+0x00c=0 clear, missing
DMA engine init). The switch port forwarding issue would prevent actual
data frames but shouldn't block AN signaling.

---

## Detailed Register Analysis

### 1. Mainline mtk-ge.c `mt7531_phy_config_init` — ALL writes

| Step | Register | What | Our v88/v89? |
|------|----------|------|-------------|
| 1 | C22 page=0x0001 reg 0x14 bit 4 | EN_DOWNSHIFT | ✅ v88(e) |
| 2 | TR ch=1 node=0xf daddr=0x17 bits 22:15=0x5e | SlvDPSready time | ✅ v88(d) |
| 3 | MMD 0x1e reg 0x123 | 100M MSE threshold = 0xffff | ✅ v88(c) |
| 4 | MMD 0x1e reg 0xa6 bits 15:8 | Near-echo offset = 0x3 | ✅ v88(a) |
| 5 | MMD 0x1e reg 0xc6 bits 9:8 | RX ADC bias = 0x3 | ✅ v88(b) |
| 6 | MMD 0x1e reg 0x13 | GBE TX delay PAIR_B/D=0x4 | ✅ v89(g) |
| 7 | MMD 0x1e reg 0x14 | Test TX delay PAIR_B/D=0x4 | ✅ v89(g) |

**ALL 7 mainline PHY-level writes are already in our patches. There is
no missing PHY register that enables TX.**

### 2. Mainline mt7530.c DSA driver — what we NEVER do

These operate on the SWITCH (via MDIO indirect or MMIO), not the PHY:

#### 2a. CORE PLL Enable (MMD VEND2 reg 0x403)

```
/* mt7531_setup() at line 2554-2563 */
val = mt7531_ind_c45_phy_read(priv, CTRL_PHY_ADDR, MDIO_MMD_VEND2, 0x403);
val |= MT7531_RG_SYSPLL_DMY2 | MT7531_PHY_PLL_BYPASS_MODE;  // bits 6,4
val &= ~MT7531_PHY_PLL_OFF;                                   // clear bit 5
mt7531_ind_c45_phy_write(priv, CTRL_PHY_ADDR, MDIO_MMD_VEND2, 0x403, val);
```

This writes to **MMD VEND2 (0x1f) register 0x403** at the SWITCH's
internal PHY address (controlled by `MT753X_CTRL_PHY_ADDR`). On PS4,
Orbis also writes to MMD 0x1f, but our v87 patch context said:

> "Confirmed: PLL confirmed ON (MMD 0x1f reg 0x403 bit 5 = 0)"

So bit 5 (PHY_PLL_OFF) is already cleared on PS4. This write is likely
done by the Orbis mts_mac_init sequence (which does C45 writes to MMD
0x1f at various register addresses). **Not missing.**

#### 2b. Switch Port MAC Configuration (PMCR register)

This is the **critical missing piece**:

```
/* mt7531_setup_common() - force link down on all ports */
for (i = 0; i < num_ports; i++)
    mt7530_rmw(priv, MT753X_PMCR_P(i),
               PMCR_LINK_SETTINGS_MASK | MT7531_FORCE_MODE_MASK,
               MT7531_FORCE_MODE_MASK);
               // = set all force-mode bits, clear MAC TX/RX enable

/* mt753x_phylink_mac_link_up() - when link comes up */
mcr = PMCR_MAC_RX_EN | PMCR_MAC_TX_EN | PMCR_FORCE_LNK;
mcr |= PMCR_FORCE_SPEED_1000;  // for 1000Mbps
mcr |= PMCR_FORCE_FDX;          // for full duplex
mt7530_set(priv, MT753X_PMCR_P(port), mcr);
    // MT753X_PMCR_P(x) = 0x3000 + (x) * 0x100
```

PMCR register bits (from mt7530.h):
```
PMCR_MAC_TX_EN     = BIT(14)   // Switch port TX enable
PMCR_MAC_RX_EN     = BIT(13)   // Switch port RX enable
PMCR_FORCE_LNK     = BIT(0)    // Force link up
PMCR_FORCE_SPEED_1000 = BIT(3) // Force 1000Mbps
PMCR_FORCE_FDX     = BIT(1)    // Force full duplex
PMCR_EXT_PHY       = BIT(17)   // External PHY mode
MT7531_FORCE_MODE_LNK = BIT(31) // MT7531-specific force link
MT7531_FORCE_MODE_SPD = BIT(30) // MT7531-specific force speed
MT7531_FORCE_MODE_DPX = BIT(29) // MT7531-specific force duplex
```

**Our driver NEVER writes PMCR.** The Orbis MTS driver sends equivalent
configuration via in-band management frames (ethertype 0xFA42) to the
switch. But if those frames aren't being transmitted or received
correctly, the switch port stays in its default state.

#### 2c. Port Forwarding Matrix (PCR register)

```
/* Setup: disable forwarding on all ports */
mt7530_rmw(priv, MT7530_PCR_P(i), PCR_MATRIX_MASK, PCR_MATRIX_CLR);

/* When link up: enable forwarding */
mt7530_write(priv, MT7530_PCR_P(port), PCR_MATRIX(user_ports));
```

Again, Orbis manages this via management frames. Our Linux driver doesn't
send those frames.

#### 2d. RGMII Clock/Delay Setup (CLKGEN_CTRL at 0x7500)

```
/* mt7531_rgmii_setup() */
val = mt7530_read(priv, MT7531_CLKGEN_CTRL);  // offset 0x7500
val |= GP_CLK_EN;
val &= ~GP_MODE_MASK;
val |= GP_MODE(MT7531_GP_MODE_RGMII);  // = 3
val &= ~CLK_SKEW_IN_MASK;
val |= CLK_SKEW_IN(MT7531_CLK_SKEW_NO_CHG);  // = 0
val &= ~CLK_SKEW_OUT_MASK;
val |= CLK_SKEW_OUT(MT7531_CLK_SKEW_NO_CHG);  // = 0
val |= TXCLK_NO_REVERSE | RXCLK_NO_DELAY;
// If RGMII_ID: clear both TXCLK_NO_REVERSE and RXCLK_NO_DELAY
// If RGMII_TXID: clear only RXCLK_NO_DELAY
mt7530_write(priv, MT7531_CLKGEN_CTRL, val);
```

This is a SWITCH register (0x7500), not a PHY register. It configures the
RGMII interface between the MAC and the switch port. **On PS4, the Orbis
driver configures the equivalent via the MAC-side BAR+0x008 register
(which ORs in 0x07597C00) and BAR+0x074 (= 0x2277 pause values).**

#### 2e. EEE Disable on all PHYs

```
for (i = ctrl_phy; i < ctrl_phy + 5; i++)
    mt7531_ind_c45_phy_write(priv, i, MDIO_MMD_AN, MDIO_AN_EEE_ADV, 0);
```

This writes to the PHY's MDIO_MMD_AN (MMD 7) register 0x3C (EEE
advertisement), clearing all EEE capabilities. On PS4, Orbis doesn't
need to do this explicitly because the PHY's default EEE advertisement
doesn't include anything the partner can't do. However, disabling EEE
eliminates a potential source of link negotiation issues.

**Our driver does NOT disable EEE advertisement.** Consider adding:
```
mts_smi_c45_write(mts, 7, 0x3C, 0);  // Disable EEE advertisement
```

### 3. Mainline mtk-ge.c helpers — `genphy_resume`

The mtk-ge.c driver relies on the PHY framework's `genphy_resume`
which does:
```c
// drivers/net/phy/phy_device.c genphy_resume():
phy_modify(phydev, MII_BMCR, BMCR_PDOWN, 0);
// = clear bit 11 (Power Down) in BMCR register 0
```

**Our driver does a soft-reset (BMCR=0x8000) then enables AN (BMCR=0x1200),
both of which implicitly clear Power Down. This is not missing.**

### 4. Token Ring (TR) access — what Orbis does beyond mainline

The Orbis `mts_mac_init` does several TR writes via C22 page 0x52b5 that
go BEYOND what mainline mtk-ge.c does:

| Orbis TR write | Our driver? | Purpose |
|---|---|---|
| reg 0x11=0xb90a, 0x12=0x6f, 0x10=0x8f82 | ❌ unverified | Unknown analog tuning |
| reg 0x11=0xbaef, 0x12=0x2e, 0x10=0x968c | ❌ unverified | Unknown analog tuning |
| reg 0x11=0x704d, 0x12=0, 0x10=0x9698 | ❌ unverified | Unknown analog tuning |
| reg 0x11=0x344f, 0x12=2, 0x10=0x969a | ❌ unverified | Unknown analog tuning |
| reg 0x11=4, 0x12=0, 0x10=0x9686 | ❌ unverified | Unknown analog tuning |
| reg 0x11=0x671, 0x12=6, 0x10=0x8fae | ✅ v88(d) SlvDPSready | DSP timeout |

The TR writes with register 0x10 commands (0x8f82, 0x968c, 0x9698,
0x969a, 0x9686) target different TR channels/nodes (decoded from the
command). These are NOT in mainline at all. They likely tune analog
parameters specific to the PS4 board layout. Whether they affect TX
output enable is unknown but unlikely — they look like DSP/AFE tuning.

---

## What's Missing — Sorted by Impact

### HIGHEST IMPACT: MAC-side initialization (from v90 findings)

The v90 research showed that our Linux driver skips the entire `msk_init_hw`
phase that Orbis runs before `mts_mac_init`. Key missing BAR writes:

1. **BAR+0x00c = 0** — full clear of MAC_CTRL2 (we only clear bit 7)
2. **BAR+0x004 = 8** — initial link/control value
3. **BAR+0x014 = 0** — clear MAC address before setting real one
4. **BAR+0xe80 sequence (1→2→8)** — TX DMA engine enable
5. **BAR+0xe08 = 2, BAR+0xe18 = 2→1** — TX DMA control
6. **BAR+0x138 = 2→1** — unknown reset sequence

Without these, the MAC's TX path may not be functional enough to assert
a valid link signal to the PHY, explaining why BAR+0x04 bit 0 won't
latch AND why the partner sees no carrier.

### HIGH IMPACT: Switch port PMCR configuration

The DSA driver writes PMCR with `PMCR_MAC_TX_EN | PMCR_MAC_RX_EN |
PMCR_FORCE_LNK` when link comes up. On PS4, the Orbis `gbe:ctrl` thread
sends equivalent configuration via management frames. If we can't send
those frames (because TX DMA isn't initialized), the switch port stays
in default/isolated state.

**Two options:**
- (a) Initialize MAC-side DMA properly (from v90 findings) so management
  frames work — then send the same frames Orbis sends
- (b) Write PMCR directly via MDIO (if we can reach the switch's
  management port at PHY address 0x1f or similar)

### MEDIUM IMPACT: EEE advertisement disable

```
mts_smi_c45_write(mts, 7, 0x3C, 0);  // Disable all EEE advertisement
```

Simple to add, eliminates EEE as a negotiation variable.

### LOW IMPACT: Remaining Orbis TR writes

The 5 TR writes in Orbis's mts_mac_init that aren't in mainline or our
driver. These are DSP/AFE tuning writes that likely don't affect TX
output enable but may improve signal quality on the PS4's board.

### NOT NEEDED

- PHY PWRDOWN clear (MMD 1 reg 0): BMCR bit 11 is already 0 after our
  soft-reset
- PHY output enable: MT7531 doesn't have a separate output-enable bit
- MMD 0x1f reg 0x403 PLL: already confirmed bit 5 = 0 (PLL on)
- RGMII delay: already done in v89

---

## Recommended v92 Actions

### v92-A (critical): Add missing MAC registers from v90

Already identified in v90 research. This is the #1 fix to try:

```c
writel(0, bar + MTS_MAC_CTRL2);       // BAR+0x00c = 0 (full clear)
(void)readl(bar + MTS_MAC_CTRL2);     // flush
writel(8, bar + MTS_LINK_STATUS);      // BAR+0x004 = 8 (initial value)
writel(0, bar + MTS_MAC_ADDR0_HI);     // BAR+0x014 = 0 (clear MAC addr)
```

### v92-B: Disable EEE advertisement

```c
mts_smi_c45_write(mts, 7, 0x003c, 0);  // MDIO_MMD_AN, MDIO_AN_EEE_ADV = 0
```

### v92-C: TX DMA engine init (if v92-A doesn't help)

```c
writel(2, bar + 0xe08);   // TX DMA control
writel(2, bar + 0xe18);   // TX DMA reset
writel(1, bar + 0xe18);   // TX DMA init
writel(1, bar + 0xe80);   // TX DMA engine enable step 1
writel(2, bar + 0xe80);   // TX DMA engine enable step 2
writel(8, bar + 0xe80);   // TX DMA engine enable step 3
```

---

## Verification Checklist

- [x] All mtk-ge.c mt7531_phy_config_init writes match our v88/v89 patches
- [x] mt7530.c mt7531_setup PHY PLL enable at MMD VEND2 0x403 — bit 5 already 0 on PS4
- [x] mt7530.c PMCR force-link-up = switch-side operation, not PHY-side
- [x] mt7530.c CLKGEN_CTRL = switch-side register, Mac-side equivalent is BAR+0x008
- [x] No PWRDOWN or OUTPUT_EN register exists in MT7531 PHY
- [x] genphy_resume BMCR_PDOWN clear — already done by our BMCR reset
- [x] TR writes — only SlvDPSready (0x5e) is in mainline; rest are Orbis-specific tuning