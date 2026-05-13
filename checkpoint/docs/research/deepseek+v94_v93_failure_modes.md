# deepseek+v94_v93_failure_modes.md — 2026-05-13

v93 added netdev+NAPI+ring management atop v91's working link-up. Seven
likely failure modes, root causes, and fix snippets.

## Failure table

### (1) Kernel hangs on probe — NAPI scheduled before enabled

**Root cause:** IRQ fires between `request_irq` (line 718) and `register_netdev`
(line 733). ISR calls `napi_schedule_prep` on already-added-but-not-enabled
NAPI; prep succeeds, `__napi_schedule_irqoff` enqueues softirq. Softirq runs
`mts_poll` which calls `napi_complete_done` on disabled NAPI → state corruption
or double-schedule.

**Fix (8 LOC):** move `netif_napi_add` to AFTER `register_netdev` and gate ISR
with an explicit flag set only after ndo_open:

```diff
-	netif_napi_add(ndev, &mts->napi, mts_poll);
 	...
+	mts->napi_ready = false;
 	ret = register_netdev(ndev);
+	netif_napi_add(ndev, &mts->napi, mts_poll);
```

In ISR (line 241):
```diff
-	if (mts->ndev && (status & MTS_IRQ_NAPI_MASK)) {
+	if (mts->napi_ready && (status & MTS_IRQ_NAPI_MASK)) {
```

In ndo_open, after `napi_enable`:
```diff
+	mts->napi_ready = true;
```

### (2) ndo_open fails — ring init consumes 256 SKBs at 1536 bytes each silently

**Root cause:** `mts_rx_alloc` calls `netdev_alloc_skb_ip_align` 256 times in
`mts_rings_init`. On low-memory PS4 Jaguar with minimal rootfs, this can fail
after 1-10 descriptors, leaving rings with partial RX coverage. Subsequent
NAPI poll calls `mts_rx_drain` on HW-completed entries with `OWN=1` but
NULL skb → `stats.rx_errors++` → skb leak → eventual OOM.

**Fix (6 LOC):** short-circuit ndo_open if fewer than 16 RX descriptors filled:

```diff
static void mts_rings_init(struct mts *mts)
{
	unsigned int i, rx_filled = 0;
	...
	for (i = 0; i < MTS_NUM_RX_DESC; i++) {
		if (mts_rx_alloc(mts, i))
			break;
+		rx_filled++;
	}
+	if (rx_filled < 16)
+		return -ENOMEM;  // propagated by mts_open
}
```

### (3) Carrier never ON — ISR link-change handler fires before ndev ready

**Root cause:** `mts_intr` (line 280) checks `if (mts->ndev)` and calls
`netif_carrier_on`.  But `mts->ndev` is set at line 688 (before request_irq),
and the link-change IRQ can fire during probe.  In v91 link comes up at probe
time; ISR fires bit 4, sets carrier before register_netdev completes. This
should be harmless (netif_carrier_on on non-registered netdev is safe).

HOWEVER: if `mts_open` is called later (via `ip link set up`), it also checks
BAR+0x04 at line 429-432 and sets carrier.  Race: ISR link-change fires between
open's carrier check and the subsequent carrier op. Mitigated by netif_carrier
being idempotent.

**Fix (4 LOC):** remove probe-time ISR link-change carrier handling; do it
only in mts_open + NAPI poll:

```diff
 	if (status & MTS_IRQ_LINK_CHANGE) {
-		... netif_carrier_on/off ...
+		/* handled by mts_open + phy_ctrl kthread */
 	}
```

### (4) TX kick BAR+0x34 vs 0x38 is SWAPPED — HIGHEST RISK

**Root cause:** v93 hermes labels (`MTS_TX_CTRL=0x034`, `MTS_RX_CTRL=0x038`)
are swapped vs the Orbis-decompile ground truth.  From `mts_init_rings_kick`
(FUN_c85ef1b0):
```
BAR+0x34 |= 1   // bit 0 = RX engine restart
BAR+0x38 |= 1   // bit 0 = TX engine restart
```
From `mts_intr` (FUN_c85edcf0) error recovery on IRQ bit 0x22:
```
BAR+0x38 |= 4   // bit 2 = TX restart kick (NOT RX)
```
**0x34 = RX engine, 0x38 = TX engine.**  The old v82-v91 constants were CORRECT.
Hermes got the swap from misreading the mts_intr decompile or the RE doc.

v93 `mts_start_xmit` kicks `MTS_TX_CTRL` = 0x34 → kicks RX engine, TX never
starts. `mts_rx_drain` kicks `MTS_RX_CTRL` = 0x38 → kicks TX engine, RX never
refills. Result: zero packets TXed or RXed.

**Fix (4 LOC):** swap the defines back:

```diff
-#define MTS_TX_CTRL		0x034
-#define MTS_RX_CTRL		0x038
+#define MTS_TX_CTRL		0x038	/* mts_init_rings_kick: BAR+0x38 for TX */
+#define MTS_RX_CTRL		0x034	/* mts_init_rings_kick: BAR+0x34 for RX */
```

### (5) TX completes but partner sees garbage — dma_wmb ordering insufficient

**Root cause:** `mts_start_xmit` (line 510-512):
```c
dma_wmb();
mts->tx_ring[entry].ctl_len = cpu_to_le32(ctl_len);
dma_wmb();
```
Second `dma_wmb()` is AFTER ctl_len write — it ensures ctl_len is visible but
doesn't fence subsequent writes. The TX kick (BAR write) might be reordered
above ctl_len, causing HW to fetch descriptor before ctl_len is visible.

**Fix (4 LOC):** use full `wmb()` before kick, not dma_wmb:

```diff
 	mts->tx_ring[entry].ctl_len = cpu_to_le32(ctl_len);
-	dma_wmb();
+	wmb();  /* ensure descriptor fully visible before kick hits BAR */
 	writel(readl(mts->bar + MTS_TX_CTRL) | MTS_KICK_PKT,
 	       mts->bar + MTS_TX_CTRL);
```

### (6) RX never fires — RX refill writing OWN as part of ctl_len, not separate

**Root cause:** `mts_rx_alloc` (line 343-345) writes `aux0`, then `dma_wmb()`,
then `ctl_len` with OWN=0.  The dma_wmb only orders prior writes vs ctl_len,
not ctl_len vs subsequent reads. Additionally: the RX refill kick in
`mts_rx_drain` writes BAR+0x38 (if fix 4 applied, this becomes 0x34 —
correct!).  But the kick is unconditional `|= MTS_KICK_PKT` — it doesn't
check if there's a previous kick still pending. On Orbis, `mts_init_rings_kick`
writes `0x34 |= 1` (bit 0), not bit 2. Bit 2 is for packet-path kicks.

The engine may already be in "kick-received" state and ignore the second kick.

**Fix (3 LOC):** use unconditional write (not RMW) for the kick to ensure edge:

```diff
-	writel(readl(mts->bar + MTS_RX_CTRL) | MTS_KICK_PKT,
-	       mts->bar + MTS_RX_CTRL);
+	writel(MTS_KICK_PKT, mts->bar + MTS_RX_CTRL);
+	(void)readl(mts->bar + MTS_RX_CTRL);
```

### (7) ndo_stop doesn't stop engines → double-open races ring state

**Root cause:** `mts_stop` (line 436-452) intentionally keeps engines running
to preserve link.  If `ip link set down; ip link set up` is run, `mts_open`
calls `mts_rings_init` which zeros rings and re-allocates SKBs while HW is
still potentially DMAing from/to the old rings. This is a use-after-free for
DMA.

**Fix (7 LOC):** safely quiesce engines in stop, restart in open:

```diff
 static int mts_stop(struct net_device *ndev)
 {
 	...
+	/* Quiesce engines without destroying link: clear bit 0 to pause.
+	 * bit 2 (packet kick) will be re-set by ndo_open. */
+	writel(readl(mts->bar + MTS_TX_CTRL) & ~0x5,
+	       mts->bar + MTS_TX_CTRL);
+	writel(readl(mts->bar + MTS_RX_CTRL) & ~0x5,
+	       mts->bar + MTS_RX_CTRL);
+	udelay(100);  /* drain in-flight DMA */
 	mts_rings_release(mts);
 	...
 }
```

And in ndo_open, after ring re-init:
```diff
+	/* Re-enable bit 0 (engine), bit 2 (packet kick via init) */
+	writel(0x5, mts->bar + MTS_TX_CTRL);
+	writel(0x5, mts->bar + MTS_RX_CTRL);
-	writel(readl(mts->bar + MTS_TX_CTRL) | 0x1, mts->bar + MTS_TX_CTRL);
-	writel(readl(mts->bar + MTS_RX_CTRL) | 0x1, mts->bar + MTS_RX_CTRL);
```

## Priority order for v94 fix

1. **(4) Swap TX/RX CTRL defines** — blocks all TX/RX, 4 LOC
2. **(7) Safe engine quiesce in stop** — prevents use-after-free DMA, 7 LOC
3. **(5) Full wmb before kick** — ensures descriptor visibility, 4 LOC  
4. **(1) Gate NAPI scheduling in ISR** — prevents init-time crash, 8 LOC
5. **(2) Ring init failure short-circuit** — prevents OOM, 6 LOC
6. **(6) Unconditional RX kick** — cleaner semantics, 3 LOC
7. **(3) Remove probe-time carrier ops** — cosmetic, 4 LOC

--- deepseek-v41, 2026-05-13
