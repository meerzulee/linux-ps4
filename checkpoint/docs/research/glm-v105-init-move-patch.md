# v105: Move mts_parent_prelude + mts_mac_init from probe to ndo_open

## Why

v104 proved that empty-ring + 5s wait still doesn't latch BAR+0x04 bit 0.
The one-shot latch window opens only during the MAC's own cold-start
transition — and by the time probe runs mts_mac_init + engine start, the
PHY has already settled. In Orbis, mts_mac_init is called from mts_ifup
(the open path), exactly when the interface transitions UP. The latch
should fire during that fresh MAC init if PHY link is already up.

## What to move

**Remove from probe (lines ~1876-1907):**
- `mts_parent_prelude(mts);`
- `mts_mac_init(mts);`
- Ring DMA address writes (writel TX_DESC_LO/HI, RX_DESC_LO/HI)
- Engine start (writel MTS_RX_KICK | MTS_ENGINE_START, etc.)
- v91 0xe80 status unit sequence

**Remove from probe (lines ~1965-1983):**
- SMI sweep diagnostic
- `mts_phy_init(mts);`
- (PHY init must also happen in ndo_open, before MAC init, so the PHY
  is in known state when the MAC samples link)

Leave in probe:
- pci_enable, iomap, DMA mask, ring alloc, ISR, timer/kthread, register_netdev

## New mts_open sequence (replace current v104 content)

```c
static int mts_open(struct net_device *ndev)
{
	struct mts *mts = netdev_priv(ndev);
	unsigned int i;
	int ret;

	netif_carrier_off(ndev);

	/* v105: full MAC + PHY init moved from probe to ndo_open.
	 * In Orbis, mts_ifup calls mts_mac_init here — the MAC's
	 * one-shot link-status latch evaluates during the fresh MAC
	 * bring-up, not during probe.  PHY must be up before MAC init
	 * so the latch sees link UP during its evaluation window. */

	synchronize_irq(mts->irq);

	/* 1. Switch chip reset + PHY clock select (was probe prelude). */
	mts_parent_prelude(mts);

	/* 2. Full MAC init: reset, CTRL1-3, MODE, PAUSE, RX_GATE, CLK,
	 *    INIT_AC, IRQ block.  This fires the one-shot latch window. */
	mts_mac_init(mts);

	/* 3. PHY init: SMI setup, AN config, v82-v89 PHY tweaks. */
	ret = mts_phy_init(mts);
	if (ret)
		dev_warn(&mts->pdev->dev,
			 "PHY init failed (%d) — link may not come up\n", ret);

	/* 4. Program ring base addresses. */
	writel(lower_32_bits(mts->tx_ring_dma), mts->bar + MTS_TX_DESC_LO);
	writel(lower_32_bits(mts->tx_ring_dma), mts->bar + MTS_TX_DESC_HI);
	writel(lower_32_bits(mts->rx_ring_dma), mts->bar + MTS_RX_DESC_LO);
	writel(lower_32_bits(mts->rx_ring_dma), mts->bar + MTS_RX_DESC_HI);

	/* 5. Populate rings.  Start with empty (like v91 probe), let
	 *    HW sample link state during engine start, then fill RX. */
	memset(mts->tx_ring_virt, 0, MTS_RING_BYTES);
	memset(mts->rx_ring_virt, 0, MTS_RING_BYTES);
	memset(mts->tx_skb, 0, sizeof(mts->tx_skb));
	memset(mts->rx_skb, 0, sizeof(mts->rx_skb));
	memset(mts->tx_dma, 0, sizeof(mts->tx_dma));
	memset(mts->rx_dma, 0, sizeof(mts->rx_dma));
	mts->tx_prod = 0;
	mts->tx_cons = 0;
	mts->rx_head = 0;

	/* 6. Start engines with empty rings. */
	writel(readl(mts->bar + MTS_RX_KICK) | MTS_ENGINE_START,
	       mts->bar + MTS_RX_KICK);
	writel(readl(mts->bar + MTS_TX_KICK) | MTS_ENGINE_START,
	       mts->bar + MTS_TX_KICK);
	writel(1, mts->bar + 0xe80);   /* STAT_RST_SET */
	udelay(10);
	writel(2, mts->bar + 0xe80);   /* STAT_RST_CLR */
	udelay(10);
	writel(8, mts->bar + 0xe80);   /* STAT_OP_ON   */
	mdelay(1);

	dev_info(&mts->pdev->dev,
		 "v105: init-in-open: BAR+0x04=0x%08x BAR+0x06c=0x%08x "
		 "RX=0x%08x TX=0x%08x\n",
		 readl(mts->bar + MTS_LINK_STATUS),
		 readl(mts->bar + 0x06c),
		 readl(mts->bar + MTS_RX_KICK),
		 readl(mts->bar + MTS_TX_KICK));

	/* 7. Populate TX/RX descriptors now (after engine start + latch window). */
	mts->tx_ring[MTS_NUM_TX_DESC - 1].ctl_len = cpu_to_le32(MTS_DESC_WRAP);
	for (i = 0; i < MTS_NUM_TX_DESC; i++) {
		u32 ctl_len = MTS_DESC_OWN;

		if (i == MTS_NUM_TX_DESC - 1)
			ctl_len |= MTS_DESC_WRAP;
		mts->tx_ring[i].ctl_len = cpu_to_le32(ctl_len);
		mts->tx_ring[i].aux0 = cpu_to_le32(MTS_DESC_TX_AUX0_FREE);
	}
	for (i = 0; i < MTS_NUM_RX_DESC; i++) {
		if (mts_rx_alloc(mts, i)) {
			dev_warn(&mts->pdev->dev,
				 "v105: RX alloc failed at %u\n", i);
			break;
		}
	}

	writel(readl(mts->bar + MTS_RX_CTRL) | MTS_KICK_PKT,
	       mts->bar + MTS_RX_CTRL);

	napi_enable(&mts->napi);
	netif_start_queue(ndev);

	/* 8. Log final state. */
	dev_info(&mts->pdev->dev,
		 "v105: post-populate: BAR+0x04=0x%08x BAR+0x06c=0x%08x\n",
		 readl(mts->bar + MTS_LINK_STATUS),
		 readl(mts->bar + 0x06c));

	return 0;
}
```

## What to remove from probe (lines ~1876-1983)

Cut these blocks from `mts_probe`:

**Block A: MAC init (lines ~1876-1907)**
```c
	// DELETE: mts_parent_prelude(mts);
	// DELETE: mts_mac_init(mts);
	// DELETE: writel(TX/RX ring DMA addresses)
	// DELETE: writel(engine start)
	// DELETE: writel(0xe80 status unit sequence)
	// DELETE: v91(a) dev_info
```

**Block B: PHY probe init (lines ~1965-1983)**
```c
	// DELETE: SMI sweep (for loop)
	// DELETE: mts_phy_init(mts);
```

Leave in probe: DMA ring alloc, ISR register, timers, kthread, `register_netdev`.

## mts_remove needs update

In `mts_remove`, stop engines BEFORE freeing IRQ (already correct).
No other changes — rings are devm-allocated, netdev is devm-allocated.

## mts_stop needs update

Current `mts_stop` does NOT stop engines (v84 finding). This is fine
for the move: ndo_stop just disables NAPI + carrier, next ndo_open
runs full init again. But add a `synchronize_irq` at the top of the
NEXT `mts_open` to prevent races (already in v104).

## Risk assessment

LOW. PHY registers survive MAC reset (RTL8211 is external). Switch
chip re-probe via mts_parent_prelude is idempotent (1→msleep→2
sequence). v82-v89 PHY tuning runs inside mts_phy_init which moves
with it. The key difference: latch window now opens during
ndo_open when MAC is fresh, not during probe when PHY already settled.

## Diagnostic: what to look for in v105 boot log

1. `v105: init-in-open: BAR+0x04=0x????0b??` — if bit 0 is SET, latch
   fired. If 0, same as v97-v104.
2. `BAR+0x06c` — if bit 9 (0x200) appears, TX DMA ready gate opened.
3. RX should still work (same NAPI path).
4. TX test: `ping -I enp0s20f1 <gateway>` — if bit 9 set, TX DMA fetch
   should work.