# v118 plan: clear PHY power-down and replay Orbis AN restart

Hermes / 2026-05-14

## Concrete finding

v117 fixed the Baikal MTS IRQ/init-mode problem: moving `BAR+0x204 = 0x10001388` out of `mts_mac_init()` and into the post-ring/open path makes the full value stick, bit 18 fires once, and the storm dies. The remaining TX blocker is now below the MAC IRQ layer: the MT7531 PHY is not reaching operational link.

Fresh evidence with real link partners:

- Host direct cable test: host NIC is UP and advertising AN, but reports `NO-CARRIER`.
- Router test on PS4 PHY:
  - BMSR reg1 = `0x7969`
    - bit 5 `AN_COMPLETE` = 1
    - bit 2 `LINK_STATUS` = 0
  - LPA reg5 = `0xc5e1`
    - ACK = 1
    - 100TX_FD / 100TX / 10T_FD / 10T present
  - 1000BT_STAT reg10 = `0x4c00` or `0x7c00`
    - MS_CFG = 1, MS_FAULT = 0
    - LP_FD/LP_HD bits seen
    - local/remote receiver OK bits unstable
  - MMD 0x1e reg 0x123 100M MSE = `0xffff`, consistent with analog measurement failing/maxing out.

Interpretation: the PHY exchanged auto-negotiation pages and got partner ACK, but its PMA/PCS never declared link operational. Therefore `BAR+0x04 bit0` stays 0 and the MAC never gets its PHY-link input.

This is exactly the path Orbis `gbe:phy_ctrl` (`FUN_ffffffffc85f0480`) handles: when MAC link bit is down, it reasserts advertisements and restarts AN:

- C22 reg9 `1000BT_CTRL |= 0x0200`
- C22 reg4 `ANAR |= 0x0180`
- C22 reg0 `BMCR |= 0x1200`

Our Linux v88(f) currently does the opposite for 1000BT:

- C22 reg9 `&= ~0x0300` (no 1000BT advertise)

Given reg10 shows 1000BT status is active, v88(f) is a plausible self-inflicted gate. v118 should reverse it using the Orbis link-down recovery sequence, while also explicitly clearing power-down bits.

## Exact diagnostic read sequence

Run this once in `mts_open()` after the v117 post-ring IRQ enable block and before the existing 5-second MAC-link wait.

Initial snapshot:

1. C22 reg0: BMCR
2. C22 reg1: BMSR, read twice
   - first read catches latch-low status
   - second read is current status
3. C22 reg4: ANAR
4. C22 reg5: LPA
5. C22 reg9: 1000BT_CTRL
6. C22 reg10: 1000BT_STAT
7. C45 MMD1 reg0: PMA/PMD control
   - bit 11 (`0x0800`) is PMA/PMD power-down on standard Clause 45 PMA/PMD control registers
8. C45 MMD1 reg1: PMA/PMD status
9. C45 MMD0x1e reg0x123: 100M MSE diagnostic

Recommended log decode:

- BMCR bit11 `PD`, bit12 `AN_EN`, bit9 `AN_RESTART`, bit15 `RESET`
- BMSR bit2 `LINK`, bit5 `AN_DONE`
- LPA bit14 `ACK`, bit8 `100TX_FD`, bit7 `100TX`, bit6 `10T_FD`, bit5 `10T`
- 1000BT_STAT bit15 `MS_FAULT`, bit14 `MS_CFG`, bit13 `L_RX_OK`, bit12 `R_RX_OK`, bit11 `LP_FD`, bit10 `LP_HD`
- MMD1 reg0 bit11 `PMA_PD`

## Exact write sequence

Use this order:

1. If C45 MMD1 reg0 reads successfully and bit11 is set:

   `MMD1.0 = MMD1.0 & ~0x0800`

2. Read C22 reg4, then:

   `reg4 |= 0x0180`

3. Read C22 reg9, then:

   `reg9 |= 0x0200`

4. Read C22 reg0 BMCR, then write:

   `BMCR = (BMCR & ~0x0800) | 0x1200`

The explicit `& ~0x0800` matters. Orbis has code paths that write BMCR `0x0800` for PHY power-down; a plain `BMCR |= 0x1200` would preserve power-down and produce `0x1a00`, which restarts AN while still powered down.

## 5-second polling loop spec

After the write sequence, poll for 5 seconds at 100 ms cadence (50 iterations):

Each poll should read/log when changed:

1. C22 reg1 BMSR twice
2. C22 reg5 LPA
3. C22 reg10 1000BT_STAT
4. C45 MMD0x1e reg0x123 MSE
5. `BAR+0x04` link status
6. `BAR+0x38` RX engine control/status
7. `BAR+0x50` IRQ status
8. Optional: `BAR+0x06c` TX-ready status

Stop early only if both are true:

- BMSR current read has bit2 link status set
- `BAR+0x04 bit0` is set

Otherwise run the full 5 seconds so the UART log captures the failure shape.

## Expected log signals

Success signal:

- Before v118: BMSR `0x7969` or similar (`AN_DONE=1`, `LINK=0`)
- After v118:
  - BMSR current read gains bit2, e.g. `0x796d` or equivalent
  - LPA remains valid and ACKed
  - 1000BT_STAT stabilizes; receiver OK bits stop toggling or settle
  - MSE moves away from `0xffff` if the analog block starts measuring
  - `BAR+0x04` transitions from `0x...b18` to `0x...b19` or any value with bit0 set
  - `BAR+0x38 bit0` may start accepting or RX status changes
  - TX-ready path (`BAR+0x06c bit9`) may become possible

Failure signal:

- BMCR/ANAR/1000BT_CTRL writes stick, but:
  - BMSR bit5 remains 1 and bit2 remains 0
  - LPA still ACKs
  - reg10 still toggles or remains unstable
  - MSE remains `0xffff`
  - `BAR+0x04 bit0` remains 0

If v118 fails this way, the AN advertisement is not the gate. Next likely targets are PHY analog power/PLL/TX-disable/isolation state:

- C45 MMD1 PMA power-down or reset state
- v86 PLL enable at MMD0x1f reg0x403 not persisting
- MMD0x1e analog/test/TX-disable bits
- switch/PHY reset prelude leaving the external port isolated

## Pasteable C-language patch block

Paste the helper below near `mts_phy_an_restart()` or another local helper area above `mts_open()`.

```c
static void mts_v118_phy_power_an_restart(struct mts *mts)
{
	u16 bmcr0 = 0xffff, bmcr1 = 0xffff;
	u16 bmsr_latch = 0xffff, bmsr_cur = 0xffff;
	u16 anar0 = 0xffff, anar1 = 0xffff;
	u16 lpa = 0xffff;
	u16 ctrl1000_0 = 0xffff, ctrl1000_1 = 0xffff;
	u16 stat1000 = 0xffff;
	u16 pma_ctrl0 = 0xffff, pma_ctrl1 = 0xffff;
	u16 pma_stat = 0xffff;
	u16 mse = 0xffff;
	u32 linkreg, rx_ctrl, irq_status, tx_ready;
	int i;

	mts_smi_c22_read(mts, 0x00, &bmcr0);
	mts_smi_c22_read(mts, 0x01, &bmsr_latch);
	mts_smi_c22_read(mts, 0x01, &bmsr_cur);
	mts_smi_c22_read(mts, 0x04, &anar0);
	mts_smi_c22_read(mts, 0x05, &lpa);
	mts_smi_c22_read(mts, 0x09, &ctrl1000_0);
	mts_smi_c22_read(mts, 0x0a, &stat1000);
	mts_smi_c45_read(mts, 0x01, 0x0000, &pma_ctrl0);
	mts_smi_c45_read(mts, 0x01, 0x0001, &pma_stat);
	mts_smi_c45_read(mts, 0x1e, 0x0123, &mse);

	dev_info(&mts->pdev->dev,
		 "v118 pre: BMCR=0x%04x[PD=%d AN=%d RST_AN=%d RESET=%d] BMSR latch=0x%04x cur=0x%04x[LINK=%d AN_DONE=%d] ANAR=0x%04x LPA=0x%04x[ACK=%d] 1000CTL=0x%04x 1000STAT=0x%04x PMA_CTRL=0x%04x[PWRDN=%d] PMA_STAT=0x%04x MSE=0x%04x BAR04=0x%08x\n",
		 bmcr0, !!(bmcr0 & 0x0800), !!(bmcr0 & 0x1000),
		 !!(bmcr0 & 0x0200), !!(bmcr0 & 0x8000),
		 bmsr_latch, bmsr_cur, !!(bmsr_cur & 0x0004),
		 !!(bmsr_cur & 0x0020), anar0, lpa, !!(lpa & 0x4000),
		 ctrl1000_0, stat1000, pma_ctrl0, !!(pma_ctrl0 & 0x0800),
		 pma_stat, mse, readl(mts->bar + MTS_LINK_STATUS));

	/* Clear C45 PMA/PMD power-down if it is asserted. */
	if (pma_ctrl0 != 0xffff && (pma_ctrl0 & 0x0800)) {
		mts_smi_c45_write(mts, 0x01, 0x0000, pma_ctrl0 & ~0x0800);
		msleep(10);
		mts_smi_c45_read(mts, 0x01, 0x0000, &pma_ctrl1);
		dev_info(&mts->pdev->dev,
			 "v118: MMD1 PMA_CTRL 0x%04x -> 0x%04x (clear power-down)\n",
			 pma_ctrl0, pma_ctrl1);
	}

	/* Orbis gbe:phy_ctrl event-1 sequence: reassert advertisements. */
	mts_smi_c22_read(mts, 0x04, &anar0);
	anar1 = anar0 | 0x0180;
	if (anar1 != anar0)
		mts_smi_c22_write(mts, 0x04, anar1);

	mts_smi_c22_read(mts, 0x09, &ctrl1000_0);
	ctrl1000_1 = ctrl1000_0 | 0x0200;
	if (ctrl1000_1 != ctrl1000_0)
		mts_smi_c22_write(mts, 0x09, ctrl1000_1);

	/* Restart AN, but do not preserve PHY power-down. */
	mts_smi_c22_read(mts, 0x00, &bmcr0);
	bmcr1 = (bmcr0 & ~0x0800) | 0x1200;
	mts_smi_c22_write(mts, 0x00, bmcr1);

	dev_info(&mts->pdev->dev,
		 "v118: AN restart writes ANAR 0x%04x->0x%04x 1000CTL 0x%04x->0x%04x BMCR 0x%04x->0x%04x\n",
		 anar0, anar1, ctrl1000_0, ctrl1000_1, bmcr0, bmcr1);

	for (i = 0; i < 50; i++) {
		msleep(100);

		mts_smi_c22_read(mts, 0x01, &bmsr_latch);
		mts_smi_c22_read(mts, 0x01, &bmsr_cur);
		mts_smi_c22_read(mts, 0x05, &lpa);
		mts_smi_c22_read(mts, 0x0a, &stat1000);
		mts_smi_c45_read(mts, 0x1e, 0x0123, &mse);
		linkreg = readl(mts->bar + MTS_LINK_STATUS);
	rx_ctrl = readl(mts->bar + MTS_RX_CTRL);
		irq_status = readl(mts->bar + MTS_IRQ_STATUS);
		tx_ready = readl(mts->bar + 0x06c);

		if (i == 0 || i == 4 || i == 9 || i == 19 || i == 29 ||
		    i == 39 || i == 49 ||
		    ((bmsr_cur & 0x0004) && (linkreg & 0x1))) {
			dev_info(&mts->pdev->dev,
				 "v118 poll %d00ms: BMSR latch=0x%04x cur=0x%04x[LINK=%d AN_DONE=%d] LPA=0x%04x[ACK=%d] 1000STAT=0x%04x[L_RX=%d R_RX=%d LP_FD=%d LP_HD=%d MS_CFG=%d MS_FAULT=%d] MSE=0x%04x BAR04=0x%08x RX38=0x%08x IRQ50=0x%08x BAR06c=0x%08x\n",
				 i + 1, bmsr_latch, bmsr_cur,
				 !!(bmsr_cur & 0x0004), !!(bmsr_cur & 0x0020),
				 lpa, !!(lpa & 0x4000), stat1000,
				 !!(stat1000 & 0x2000), !!(stat1000 & 0x1000),
				 !!(stat1000 & 0x0800), !!(stat1000 & 0x0400),
				 !!(stat1000 & 0x4000), !!(stat1000 & 0x8000),
				 mse, linkreg, rx_ctrl, irq_status, tx_ready);
		}

		if ((bmsr_cur & 0x0004) && (linkreg & 0x1))
			break;
	}

	dev_info(&mts->pdev->dev,
		 "v118 result: waited %d00ms final BMSR=0x%04x BAR04=0x%08x RX38=0x%08x IRQ50=0x%08x BAR06c=0x%08x\n",
		 i + 1, bmsr_cur, readl(mts->bar + MTS_LINK_STATUS),
		 readl(mts->bar + MTS_RX_CTRL), readl(mts->bar + MTS_IRQ_STATUS),
		 readl(mts->bar + 0x06c));
}
```

Then insert this call in `mts_open()` immediately after the v117 post-ring IRQ enable block and before the existing `/* 4. Wait for MAC bit 0 latch */` loop:

```c
	/*
	 * v118: With v117 fixing the IRQ/init-mode storm, the remaining
	 * blocker is PHY-level link: BMSR reports AN complete + partner ACK,
	 * but LINK_STATUS remains 0 and the host/router may see no carrier.
	 * Reproduce Orbis gbe:phy_ctrl's link-down recovery once before the
	 * MAC link-latch wait: clear power-down, reassert advertisements, and
	 * restart AN.
	 */
	mts_v118_phy_power_an_restart(mts);
```

## Notes / caveats

- This intentionally reverses v88(f) for one experiment. If link comes up, v88(f) should be removed or gated.
- `MMD1.0` reads can legitimately fail or return `0xffff` on some MDIO implementations; the helper treats `0xffff` as no usable C45 PMA control value and skips the write.
- If this is hotswapped into the current driver, verify the module contains `v118` strings before loading:

  `strings drivers/net/ethernet/sony/ps4_mts.ko | grep v118`

- If v118 succeeds, the next cleanup should move this from a one-shot `mts_open()` experiment into the existing `mts_phy_ctrl_fn()` heartbeat/event path, matching Orbis more closely.
