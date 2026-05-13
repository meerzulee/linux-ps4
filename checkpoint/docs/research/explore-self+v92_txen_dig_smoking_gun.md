# Explore self-dig — v92 candidate: MMD 0x1e reg 0x144 bit 5 TXEN_DIG (2026-05-13)

## TL;DR

Mainline `mtk-ge-soc.c:976-978` clears bit 5 of MMD 0x1e reg 0x144
(`MTK_PHY_RG_TXEN_DIG_MASK` in `MTK_PHY_RG_TESTMUX_ADC_CTRL`) inside
`mt798x_phy_eee()` for **mt798x only**. MT7531 driver (`mtk-ge.c`)
never touches register 0x144 anywhere. If MT7531 has the same vendor-
MMD register layout (likely — same MediaTek PHY family, same vendor
space), POR value bit 5 = 1 would leave the digital TX path gated.

This is the strongest candidate for "PHY can RX but can't TX" that
v91 cable swap proved.

## Verification — primary sources

`tmp/vanilla-6.15.4/drivers/net/phy/mediatek/mtk-ge-soc.c`:

- Line 205: `#define MTK_PHY_RG_TESTMUX_ADC_CTRL  0x144`
- Line 206: `#define   MTK_PHY_RG_TXEN_DIG_MASK   GENMASK(5, 5)` (bit 5)
- Lines 976-978 (inside `mt798x_phy_eee`):
  ```
  phy_clear_bits_mmd(phydev, MDIO_MMD_VEND1,
                     MTK_PHY_RG_TESTMUX_ADC_CTRL,
                     MTK_PHY_RG_TXEN_DIG_MASK);
  ```
- Line 1209 calls `mt798x_phy_eee(phydev)` from `mt798x_phy_config_init`

`tmp/vanilla-6.15.4/drivers/net/phy/mediatek/mtk-ge.c` (MT7531 driver):

- `mt7531_phy_config_init` (line 76) — does NOT touch 0x144.
- grep for `0x144|TXEN_DIG|TESTMUX_ADC_CTRL` returns 0 hits.

## Interpretation

- "TXEN_DIG" = "Transmit Enable, Digital" — gates the digital pre-driver
  feeding the analog line driver.
- `TESTMUX_ADC_CTRL` (in mainline naming) is a test/calibration register
  in the analog-control block; bit 5 is dual-purpose for test gating + TX
  enable.
- mt798x clears this bit during EEE init.  EEE depends on the TX driver
  being controllable, so the bit is cleared to "TX driver always on
  (not test-muxed)".  For non-EEE chips like MT7531, mainline assumes
  the bit is correctly cleared by POR/efuse calibration — but PS4
  Baikal's MT7531 might have a different POR state, especially since
  Sony's Orbis driver does its own "Realtek pokes" that may stomp this.

## Risk assessment

- **Risk:** Clearing bit 5 of a register at MMD 0x1e reg 0x144 on
  MT7531 without confirmation it has the same layout.
- **Mitigation:** READ the register FIRST.  Log POR value.  If bit
  5 == 1, clear it.  If bit 5 == 0 already, do not write.  Two-step:
  read + conditional clear.

## v92 plan (if v91 doesn't fix link)

Insert after v89's RGMII delays, before final BMCR AN restart:

```c
/* v92: clear MMD 0x1e reg 0x144 bit 5 (TXEN_DIG mask) per mainline
 * mt798x_phy_eee (mtk-ge-soc.c:976-978).  Untouched by MT7531 driver
 * in mainline but assumed POR-cleared by other chips — PS4 Baikal
 * Orbis driver's Realtek pokes may have stomped this. */
if (mts_smi_c45_read(mts, 0x1e, 0x0144, &v16) == 0) {
    if (v16 & 0x0020) {
        mts_smi_c45_write(mts, 0x1e, 0x0144, v16 & ~0x0020);
        dev_info(&pdev->dev,
            "v92: TXEN_DIG clear MMD0x1e r0x144 0x%04x -> 0x%04x\n",
            v16, v16 & ~0x0020);
    } else {
        dev_info(&pdev->dev,
            "v92: TXEN_DIG MMD0x1e r0x144 already 0x%04x (bit5=0), no write\n", v16);
    }
}
```

## Cross-check pending

Wait for hermes/glm/kimi/deepseek findings — see if any of them
independently identify TXEN_DIG, or find a different / conflicting
TX-enable candidate.  Multi-agent convergence raises confidence
significantly (per CLAUDE.md sanity-check rule).

## Confidence

- Register identity (0x144 bit 5 = TXEN_DIG in mt798x mainline):
  **VERIFIED, high confidence**.
- MT7531 has same register at same address: **inferred, medium
  confidence**.  MediaTek PHY family typically shares MMD 0x1e vendor
  layout across closely-related chips.
- This is the cause of PS4 MT7531's TX failure: **hypothesis, medium-
  high confidence**.  Best candidate so far given Phase 2 data, but
  needs the readout to prove POR=1 before we can be sure.
