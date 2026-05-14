// SPDX-License-Identifier: GPL-2.0-only
/*
 * Sony PS4 Baikal "MTS" gigabit ethernet driver.
 *
 * Reverse-engineered from Orbis kernel FW 12.02 `if_mts.c`.  Full register map
 * and ISR bit table at checkpoint/docs/research/2026-05-12-orbis-mts-driver-RE.md.
 *
 * History:
 *  - v77/v77b (2026-05-12): PCI bind + SMI MDIO C22 + PHY ID readback.
 *  - v82-v89 (2026-05-12..13): parent prelude, mac_init, kthread SMI
 *    heartbeat, ISR stub, engine start, MT7531 DSP corrections from
 *    mainline (SlvDPSready TR write, RGMII delays).
 *  - v91 (2026-05-13): status unit OP_ON + MMD diagnostic — LINK UP
 *    1000Mb/s Full Duplex confirmed both sides with RTL8153 partner.
 *  - v93 (2026-05-13): netdev wrapper — alloc_etherdev, register_netdev,
 *    ndo_open/stop/start_xmit/get_stats64, NAPI poll, real descriptor
 *    management.  Descriptor layout verified by hermes Ghidra dig:
 *    16-byte stride, INVERTED OWN semantics (driver clears bit31 to give
 *    to HW, HW sets bit31 on completion), TX SOF/EOF bits 29/28,
 *    RX length in bits 0..10, TX kick at BAR+0x34, RX refill at BAR+0x38.
 */

#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/if_ether.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/kthread.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/pci_ids.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/timer.h>
#include <linux/types.h>

#define DRV_NAME "ps4_mts"

/* BAR0 register offsets (see RE doc for full table). */
#define MTS_SMI_CMD		0x000
#define MTS_LINK_STATUS		0x004
#define MTS_MAC_CTRL1		0x008
#define MTS_MAC_CTRL2		0x00c
#define MTS_MAC_CTRL3		0x010
#define MTS_MAC_ADDR0_HI	0x014
#define MTS_MAC_ADDR0_LO	0x018
#define MTS_MAC_MODE		0x030
#define MTS_RX_KICK		0x034
#define MTS_TX_KICK		0x038
#define MTS_TX_DESC_LO		0x03c
#define MTS_RX_DESC_LO		0x040
#define MTS_TX_DESC_HI		0x044
#define MTS_RX_DESC_HI		0x048

/* Engine start bit (BAR+0x34, BAR+0x38 bit 0). */
#define MTS_ENGINE_START	0x00000001

/* IRQ status bits we care about for the stub ISR. */
#define MTS_IRQ_LINK_CHANGE	0x00000004	/* BAR+0x50 bit 2 */
#define MTS_IRQ_STATUS		0x050
#define MTS_IRQ_MASK		0x054
#define MTS_MAC_PAUSE		0x074
#define MTS_RX_GATE		0x078
#define MTS_MAC_CLK		0x07c
#define MTS_PKT_ENGINE_CTRL	0x09c
#define MTS_INIT_AC		0x0ac
#define MTS_MAC_ADDR1_HI	0x140
#define MTS_MAC_ADDR1_LO	0x144
#define MTS_MCAST_DATA		0x1bc
#define MTS_MCAST_IDX		0x1c0
#define MTS_MCAST_CTRL		0x1c4
#define MTS_MCAST_MASK		0x1c8
#define MTS_MCAST_DONE		0x1d0
#define MTS_INIT_1D4		0x1d4
#define MTS_MASTER_RESET	0x200
#define MTS_IRQ_ENABLE_FULL	0x204

/* SMI bits (BAR+0x00 is a single command/result word). */
#define MTS_SMI_ARM		0x00008000
#define MTS_SMI_OP_C22_RD	0x00004000
#define MTS_SMI_OP_C22_WR	0x00002000
#define MTS_SMI_OP_C45_ADDR	0x00000020
#define MTS_SMI_OP_C45_RD	0x000000e0
#define MTS_SMI_OP_C45_WR	0x00000060
#define MTS_SMI_REG_SHIFT	8
#define MTS_SMI_DATA_SHIFT	16
#define MTS_SMI_DONE		0x00008000 /* same bit as ARM in the lower 16 */

#define MTS_SMI_TIMEOUT_US	10000

/* Parent-prelude register block (Orbis FUN_c85131d0, see v82 RE notes). */
#define MTS_PRELUDE_60		0x060
#define MTS_PRELUDE_64		0x064
#define MTS_PRELUDE_68		0x068
#define MTS_PRELUDE_6C		0x06c
#define MTS_PRELUDE_11C		0x11c
#define MTS_PRELUDE_120		0x120
#define MTS_PRELUDE_158		0x158
#define MTS_PRELUDE_F04		0xf04	/* switch chip GPIO reset */
#define MTS_PRELUDE_F10		0xf10

/* Link status fields (BAR+0x04). */
#define MTS_LINK_UP		BIT(0)
#define MTS_LINK_SPEED_MASK	(3 << 2)
#define MTS_LINK_SPEED_10	(0 << 2)
#define MTS_LINK_SPEED_100	(1 << 2)
#define MTS_LINK_SPEED_1000	(2 << 2)
#define MTS_LINK_FULL_DUPLEX	BIT(4)

/* Init constants captured from mts_mac_init in Orbis kernel. */
#define MTS_MAC_CTRL1_INIT_OR	0x07597c00
#define MTS_MAC_CTRL3_INIT_AND	0xffffff6e
#define MTS_MAC_CTRL3_INIT_OR	0x00000081
#define MTS_MAC_MODE_INIT	0x00010100
#define MTS_MAC_PAUSE_INIT	0x00002277
#define MTS_MAC_CLK_INIT	25000000
#define MTS_IRQ_ENABLE_FULL_VAL	0x10001388
/*
 * v111: Restore bit 18 to the mask.  v85 had masked it to suppress the
 * 5,670 Hz flood, but per the Orbis mts_intr decompile (and live
 * userspace experiment 2026-05-13), the bit-18 (0x40000) IRQ is the
 * MAC's "I'm still in init mode" handshake signal.  The Orbis ISR
 * handles it by writing 0 to BAR+0x204 (master IRQ disable) + restoring
 * the saved mask to BAR+0x54 — that exits the MAC's init state machine.
 * With bit 18 MASKED (v85..v110), the handshake bit never reaches our
 * ISR and the MAC stays stuck forever: TX never completes, RX engine
 * bit 0 won't latch, link bit 0 of BAR+0x04 never sets.
 *
 * v111 mask polarity is "ENABLED bits" (Orbis: ~softc+0x3098 & status
 * gates the handshake check, i.e. softc+0x3098 = "ignored" bits, and
 * BAR+0x54 = ~ignored = enabled).  0x007bfffe enables all bits except 0
 * and 0x800000 — matching Orbis first-call.
 */
#define MTS_IRQ_BIT18		0x00040000
#define MTS_IRQ_MASK_FULL_VAL	0x007bfffe	/* v111: bit 18 included */
#define MTS_IRQ_CTRL_DONE_BIT	0x00001000	/* v115: gbe:ctrl clears BAR+0x54 bit 12 */

#define MTS_PHY_CTRL_PERIOD_MS	3000	/* gbe:phy_ctrl cadence */
#define MTS_DBG_TIMER_PERIOD_MS	5000	/* debug telemetry dump cadence */
#define MTS_ISR_HIST_SLOTS	16

/*
 * DMA descriptor ring sizing — v93 per hermes Ghidra confirm.
 * Orbis hard-codes 256 descriptors per ring (8-bit prod/cons), each ring
 * 0x1000 bytes.  RX buffer size is 0x600 (1536 bytes) — fits standard
 * 1518-byte Ethernet frame with alignment slack.
 */
#define MTS_NUM_TX_DESC		256
#define MTS_NUM_RX_DESC		256
#define MTS_DESC_BYTES		16
#define MTS_RING_BYTES		(MTS_NUM_RX_DESC * MTS_DESC_BYTES)	/* 4096 */
#define MTS_RX_BUF_SIZE		0x600
#define MTS_TX_BUF_MAX		(MTS_RX_BUF_SIZE - 64)
#define MTS_NAPI_BUDGET		64

/*
 * Hardware descriptor — 16 bytes, per hermes v93 Ghidra dig of
 * mts_init_rings_kick (FUN_c85ef1b0), mts_tx_complete (FUN_c85eeca0),
 * mts_rx_unwrap_one (FUN_c85eed90), TX submit FUN_c85f1aa0.
 *
 * CRITICAL: OWN semantics are INVERTED vs typical descriptors.
 *   - Driver CLEARS bit 31 (OWN=0) to hand the descriptor to HW.
 *   - HW SETS bit 31 (OWN=1) when the descriptor is complete/CPU-owned.
 * WRAP (bit 30) set only on descriptor index 255.
 * 32-bit DMA address; no addr_hi field.
 */
struct mts_desc {
	__le32	ctl_len;	/* +0x00: OWN/WRAP/SOF/EOF/flags/length */
	__le32	buf_lo;		/* +0x04: 32-bit DMA buffer address */
	__le32	aux0;		/* +0x08: TX sentinel/VLAN; RX VLAN tag */
	__le32	aux1;		/* +0x0c: TX TSO/csum metadata; RX unused */
} __packed __aligned(16);

#define MTS_DESC_OWN		BIT(31)		/* HW-sets-on-complete */
#define MTS_DESC_WRAP		BIT(30)		/* last entry */
#define MTS_DESC_TX_SOF		BIT(29)		/* TX: start-of-frame */
#define MTS_DESC_TX_EOF		BIT(28)		/* TX: end-of-frame */
#define MTS_DESC_RX_LEN_MASK	GENMASK(10, 0)	/* RX length (max 2047) */
#define MTS_DESC_TX_AUX0_FREE	0xffff0000u	/* sentinel: TX desc free */

/* Per hermes: BAR+0x34 is TX engine, BAR+0x38 is RX engine.  bit0 enables,
 * bit2 is the packet-path kick.  The earlier v82..v91 constants MTS_RX_KICK
 * (0x34) and MTS_TX_KICK (0x38) had swapped labels but the engine-enable
 * writes (bit0) work either way since we set both. */
#define MTS_TX_CTRL		0x034	/* TX engine: bit0=enable, bit2=kick */
#define MTS_RX_CTRL		0x038	/* RX engine: bit0=enable, bit2=refill */
#define MTS_KICK_PKT		0x04	/* bit 2: packet-path kick */

/* IRQ bits per hermes mts_intr decompile */
#define MTS_IRQ_TX_DONE		0x00000080	/* TX completion */
#define MTS_IRQ_RX_AVAIL	0x00000040	/* RX packet available */
#define MTS_IRQ_RX_KICKED	0x00000022	/* RX-related condition */
#define MTS_IRQ_NAPI_MASK	(MTS_IRQ_TX_DONE | MTS_IRQ_RX_AVAIL | MTS_IRQ_RX_KICKED)

struct mts {
	struct net_device *ndev;		/* v93: netdev wrapper */
	struct napi_struct napi;		/* v93: NAPI RX/TX poll */
	struct pci_dev *pdev;
	void __iomem *bar;
	struct timer_list link_poll;
	u32 last_link;
	struct task_struct *phy_ctrl_thread;
	u8 phy_addr;
	bool link_logged_once;
	bool last_phy_link_up;
	bool last_phy_carrier;	/* v94: PHY-derived netif_carrier state */
	bool initial_an_done;
	unsigned int link_down_iterations;

	/* v84/v93: DMA rings + per-descriptor SKB tracking. */
	struct mts_desc *tx_ring;	/* typed view of tx_ring_virt */
	struct mts_desc *rx_ring;	/* typed view of rx_ring_virt */
	void *tx_ring_virt;
	void *rx_ring_virt;
	dma_addr_t tx_ring_dma;
	dma_addr_t rx_ring_dma;
	struct sk_buff *tx_skb[MTS_NUM_TX_DESC];
	dma_addr_t tx_dma[MTS_NUM_TX_DESC];
	struct sk_buff *rx_skb[MTS_NUM_RX_DESC];
	dma_addr_t rx_dma[MTS_NUM_RX_DESC];
	u16 tx_prod;	/* driver writes here next */
	u16 tx_cons;	/* HW completion follows */
	u16 rx_head;	/* NAPI poll cursor */
	spinlock_t tx_lock;

	int irq;
	bool irq_registered;
	bool netdev_registered;
	atomic_t isr_link_change_count;

	/* v85/v93 telemetry: ISR histogram kept as debug aid. */
	atomic_t isr_total_count;
	u32 isr_hist_pattern[MTS_ISR_HIST_SLOTS];
	atomic_t isr_hist_count[MTS_ISR_HIST_SLOTS];
	u32 isr_last_linkreg;
	struct timer_list dbg_timer;

	/* v111: Orbis-style bit-18 handshake state.
	 * Set true after mts_mac_init writes BAR+0x204 + BAR+0x54 init values.
	 * Cleared on the first bit-18-only IRQ, where the ISR writes 0 to
	 * BAR+0x204 + restores BAR+0x54 from saved_irq_mask — mirroring
	 * Orbis's mts_intr "exit init mode" sequence.
	 */
	bool irq_block_armed;
	u32 saved_irq_mask;
};

/*
 * SMI MDIO Clause-22 read.  Single 32-bit command register with poll-bit-15
 * completion.  No PHY-address selector in the protocol — Sony's SMI is wired
 * to a single PHY on a private bus, so register-number is the only field.
 */
static int mts_smi_c22_read(struct mts *mts, u8 reg, u16 *val)
{
	u32 v;
	int timeout = MTS_SMI_TIMEOUT_US;

	writel(MTS_SMI_ARM, mts->bar + MTS_SMI_CMD);
	writel(MTS_SMI_OP_C22_RD | ((reg & 0x1f) << MTS_SMI_REG_SHIFT),
	       mts->bar + MTS_SMI_CMD);

	do {
		v = readl(mts->bar + MTS_SMI_CMD);
		if (v & MTS_SMI_DONE) {
			*val = v >> MTS_SMI_DATA_SHIFT;
			return 0;
		}
		udelay(1);
	} while (--timeout);

	*val = 0xffff;
	return -ETIMEDOUT;
}

static int mts_smi_c22_write(struct mts *mts, u8 reg, u16 val)
{
	u32 cmd;
	int timeout = MTS_SMI_TIMEOUT_US;

	writel(MTS_SMI_ARM, mts->bar + MTS_SMI_CMD);
	cmd = MTS_SMI_OP_C22_WR
	    | ((reg & 0x1f) << MTS_SMI_REG_SHIFT)
	    | ((u32)val << MTS_SMI_DATA_SHIFT);
	writel(cmd, mts->bar + MTS_SMI_CMD);

	do {
		if (readl(mts->bar + MTS_SMI_CMD) & MTS_SMI_DONE)
			return 0;
		udelay(1);
	} while (--timeout);

	return -ETIMEDOUT;
}

/*
 * SMI MDIO Clause-45 accessor.  C45 has a two-phase transaction:
 *   1) ADDR phase: write opcode OP_C45_ADDR | mmd_dev | (reg in upper 16)
 *   2) RD or WR phase: write OP_C45_RD/WR | mmd_dev | (data in upper 16 for WR)
 *
 * Sony's SMI packs the MMD device address into bits 8-12 (where the C22
 * register field lives) and uses the upper 16 bits for register address
 * (ADDR phase) then data (RD/WR phase).  This is an INFERRED encoding;
 * if wrong, the first C45 transaction will return unexpected data or time
 * out, and we'll need to revise based on Orbis decompile of mts_smi_cl45_*.
 */
static int mts_smi_c45_write(struct mts *mts, u8 mmd, u16 reg, u16 val)
{
	u32 cmd;
	int timeout;

	/* ADDR phase: tell PHY which MMD register we want. */
	writel(MTS_SMI_ARM, mts->bar + MTS_SMI_CMD);
	cmd = MTS_SMI_OP_C45_ADDR
	    | ((mmd & 0x1f) << MTS_SMI_REG_SHIFT)
	    | ((u32)reg << MTS_SMI_DATA_SHIFT);
	writel(cmd, mts->bar + MTS_SMI_CMD);

	timeout = MTS_SMI_TIMEOUT_US;
	do {
		if (readl(mts->bar + MTS_SMI_CMD) & MTS_SMI_DONE)
			break;
		udelay(1);
	} while (--timeout);
	if (!timeout)
		return -ETIMEDOUT;

	/* WR phase: deliver the data. */
	writel(MTS_SMI_ARM, mts->bar + MTS_SMI_CMD);
	cmd = MTS_SMI_OP_C45_WR
	    | ((mmd & 0x1f) << MTS_SMI_REG_SHIFT)
	    | ((u32)val << MTS_SMI_DATA_SHIFT);
	writel(cmd, mts->bar + MTS_SMI_CMD);

	timeout = MTS_SMI_TIMEOUT_US;
	do {
		if (readl(mts->bar + MTS_SMI_CMD) & MTS_SMI_DONE)
			return 0;
		udelay(1);
	} while (--timeout);
	return -ETIMEDOUT;
}

static int mts_smi_c45_read(struct mts *mts, u8 mmd, u16 reg, u16 *val)
{
	u32 v, cmd;
	int timeout;

	/* ADDR phase. */
	writel(MTS_SMI_ARM, mts->bar + MTS_SMI_CMD);
	cmd = MTS_SMI_OP_C45_ADDR
	    | ((mmd & 0x1f) << MTS_SMI_REG_SHIFT)
	    | ((u32)reg << MTS_SMI_DATA_SHIFT);
	writel(cmd, mts->bar + MTS_SMI_CMD);

	timeout = MTS_SMI_TIMEOUT_US;
	do {
		if (readl(mts->bar + MTS_SMI_CMD) & MTS_SMI_DONE)
			break;
		udelay(1);
	} while (--timeout);
	if (!timeout)
		return -ETIMEDOUT;

	/* RD phase. */
	writel(MTS_SMI_ARM, mts->bar + MTS_SMI_CMD);
	writel(MTS_SMI_OP_C45_RD | ((mmd & 0x1f) << MTS_SMI_REG_SHIFT),
	       mts->bar + MTS_SMI_CMD);

	timeout = MTS_SMI_TIMEOUT_US;
	do {
		v = readl(mts->bar + MTS_SMI_CMD);
		if (v & MTS_SMI_DONE) {
			*val = v >> MTS_SMI_DATA_SHIFT;
			return 0;
		}
		udelay(1);
	} while (--timeout);

	*val = 0xffff;
	return -ETIMEDOUT;
}

/*
 * MT7531 PHY core PLL enable.  Per deepseek-v41's v83 research and
 * mainline mt7531_setup (DSA switch driver):
 *
 *   MMD 0x1f (MDIO_MMD_VEND2) reg 0x403 = PHY PLL control
 *     bit 4: RG_SYSPLL_DMY2     (set)
 *     bit 5: PHY_PLL_OFF        (clear)
 *     bit 6: PHY_PLL_BYPASS_MODE (set)
 *
 * Our mts_parent_prelude() writes BAR+0xf04 = switch chip GPIO reset,
 * which destroys the bootloader's PLL state.  After this reset the MT7531
 * can still do MDIO + auto-negotiation (those work over the management
 * port) but cannot generate a link signal to the MAC (PMA/PCS clocking
 * is dead).
 *
 * v85 confirmed exactly this: SMI works, BMSR shows AN-complete, but
 * BMSR bit 2 (link status) stays 0 in BOTH halves of a double-read.
 *
 * Call this from mts_mac_init AFTER all BAR-side writes complete.
 */
static void mts_phy_pll_enable(struct mts *mts)
{
	u16 pll = 0xffff;
	int ret;

	ret = mts_smi_c45_read(mts, 0x1f, 0x403, &pll);
	if (ret) {
		dev_warn(&mts->pdev->dev,
			 "PHY PLL: C45 read MMD 0x1f reg 0x403 failed (%d) - C45 protocol may be wrong\n",
			 ret);
		return;
	}
	dev_info(&mts->pdev->dev,
		 "PHY PLL: MMD 0x1f reg 0x403 read 0x%04x (bit 5 PLL_OFF=%d)\n",
		 pll, !!(pll & (1 << 5)));

	pll |= (1 << 4) | (1 << 6);   /* RG_SYSPLL_DMY2 | PHY_PLL_BYPASS_MODE */
	pll &= ~(1 << 5);              /* clear PHY_PLL_OFF */

	ret = mts_smi_c45_write(mts, 0x1f, 0x403, pll);
	if (ret) {
		dev_warn(&mts->pdev->dev,
			 "PHY PLL: C45 write MMD 0x1f reg 0x403 = 0x%04x failed (%d)\n",
			 pll, ret);
		return;
	}
	dev_info(&mts->pdev->dev,
		 "PHY PLL: wrote MMD 0x1f reg 0x403 <- 0x%04x (PLL on, bypass mode)\n",
		 pll);

	/* Read back to confirm the write took. */
	if (mts_smi_c45_read(mts, 0x1f, 0x403, &pll) == 0)
		dev_info(&mts->pdev->dev,
			 "PHY PLL: readback MMD 0x1f reg 0x403 = 0x%04x\n",
			 pll);
}

/*
 * Parent prelude replayed from Orbis FUN_c85131d0(softc, 1).  This is the
 * "switch GPIO + clock-domain glue" sequence that the Orbis parent driver
 * (baikal_gbe_attach -> msk_init_hw) runs before any child MAC init.  Linux
 * sky2_reset has the BAR+0x60..0x6c constants but misses the BAR+0xf10/0xf04
 * GPIO reset with timing and the BAR+0x158 mode 2->1 clock-domain transition.
 *
 * The BAR+0xf04 switch-chip reset is the load-bearing one - without the 12ms
 * and 500ms recovery delays, PHYs power-down without coming back, killing SMI
 * MDC visibility.  This is what sky2_mac_init does wrong on every interface-up
 * (no delays) and why v78..v81 couldn't keep MDC alive even with B0_IMSK gated.
 */
static void mts_parent_prelude(struct mts *mts)
{
	void __iomem *bar = mts->bar;
	u32 v;

	writel(1, bar + MTS_PRELUDE_F10);
	writel(2, bar + MTS_PRELUDE_F10);

	writel(1, bar + MTS_PRELUDE_F04);
	msleep(12);
	writel(2, bar + MTS_PRELUDE_F04);
	msleep(500);

	writel(0x00032100, bar + MTS_PRELUDE_60);
	writel(0x00000006, bar + MTS_PRELUDE_64);
	writel(0x00063b9c, bar + MTS_PRELUDE_68);
	writel(0x00000300, bar + MTS_PRELUDE_6C);

	writel(1, bar + MTS_PRELUDE_120);

	v = readl(bar + MTS_PRELUDE_11C);
	writel(v & 0xf8ff, bar + MTS_PRELUDE_11C);

	v = readl(bar + MTS_PRELUDE_158);
	writel((v & ~3u) | 2, bar + MTS_PRELUDE_158);
	(void)readl(bar + MTS_PRELUDE_158);
	v = readl(bar + MTS_PRELUDE_158);
	writel((v & ~3u) | 1, bar + MTS_PRELUDE_158);
	(void)readl(bar + MTS_PRELUDE_158);
}

/*
 * Full mts_mac_init from Orbis FUN_c85ecb60.  v77's phase-1 version only did
 * MASTER_RESET + IRQ_STATUS ack + INIT_AC = 9; that wasn't enough to keep the
 * MAC clock domain alive past ~1 minute.  This version replays the rest of the
 * Orbis sequence: MAC_CTRL1 enable bits, MAC_CTRL2 clear bit 7, MAC_CTRL3
 * (clear bits 0/4/7 then set 0/7), MAC_MODE, MAC_PAUSE, RX_GATE bit 0 clear,
 * MAC_CLK = 25MHz, and finally the full IRQ block enable at BAR+0x204 +
 * per-IRQ mask at BAR+0x54.  The efuse-dependent PHY trim writes are still
 * deferred - they tune AFE parameters and aren't required for SMI to work.
 */
static void mts_mac_init(struct mts *mts)
{
	void __iomem *bar = mts->bar;
	u32 v;

	writel(0, bar + MTS_MASTER_RESET);
	(void)readl(bar + MTS_MASTER_RESET);

	writel(readl(bar + MTS_IRQ_STATUS), bar + MTS_IRQ_STATUS);

	v = readl(bar + MTS_MAC_CTRL1);
	writel(v | MTS_MAC_CTRL1_INIT_OR, bar + MTS_MAC_CTRL1);

	v = readl(bar + MTS_MAC_CTRL2);
	writel(v & ~0x80u, bar + MTS_MAC_CTRL2);

	v = readl(bar + MTS_MAC_CTRL3);
	writel((v & MTS_MAC_CTRL3_INIT_AND) | MTS_MAC_CTRL3_INIT_OR,
	       bar + MTS_MAC_CTRL3);

	writel(MTS_MAC_MODE_INIT,  bar + MTS_MAC_MODE);
	writel(MTS_MAC_PAUSE_INIT, bar + MTS_MAC_PAUSE);

	v = readl(bar + MTS_RX_GATE);
	writel(v & ~1u, bar + MTS_RX_GATE);

	writel(MTS_MAC_CLK_INIT, bar + MTS_MAC_CLK);

	udelay(680);
	writel(9, bar + MTS_INIT_AC);

	/*
	 * v110: BAR+0x1d4 = 1.  Orbis mts_mac_init writes this unconditionally
	 * after BAR+0x08 |= 0x7597c00 and before the BAR+0x10 bit-field write.
	 * Purpose unknown but consistent across the Orbis decompile.  Our
	 * driver was missing this since v82.  Verified by Ghidra MCP read of
	 * mts_mac_init @ 0xffffffffc85ecb60 in May-11 dump (see
	 * checkpoint/orbis-dumps/12.02/mts-bar0-orbis-working.bin diff).
	 */
	{
		u32 v1d4_before = readl(bar + MTS_INIT_1D4);
		writel(1, bar + MTS_INIT_1D4);
		dev_info(&mts->pdev->dev,
			 "v110: BAR+0x1d4 0x%08x -> 0x%08x (Orbis missing write)\n",
			 v1d4_before, readl(bar + MTS_INIT_1D4));
	}

	/*
	 * v117: Orbis does NOT enable BAR+0x204 from mts_mac_init.  It only
	 * writes BAR+0x200=0, ACKs BAR+0x50, performs MAC/PHY setup, then
	 * mts_init_rings_kick writes BAR+0x54 and clears softc+0x309c; the
	 * ISR first-call path enables BAR+0x204 only after rings/engines.
	 * Keep the master block OFF here to avoid prematurely entering the
	 * state where BAR+0x204 lower bits stop accepting writes (lockout
	 * empirically confirmed via userspace MMIO 2026-05-14).
	 *
	 * Write only the per-IRQ mask (BAR+0x54) here — bit 12 already
	 * carries through to v115's clear in mts_open after rings.  Arm the
	 * bit-18 handshake later, in mts_open, after BAR+0x204 has been
	 * enabled with rings ready.
	 */
	mts->saved_irq_mask = MTS_IRQ_MASK_FULL_VAL & ~MTS_IRQ_CTRL_DONE_BIT;
	mts->irq_block_armed = false;
	writel(0, bar + MTS_IRQ_ENABLE_FULL);
	writel(mts->saved_irq_mask, bar + MTS_IRQ_MASK);
	dev_info(&mts->pdev->dev,
		 "v117: mts_mac_init leaves IRQ master off (BAR+0x204=0x%08x BAR+0x54=0x%08x)\n",
		 readl(bar + MTS_IRQ_ENABLE_FULL), readl(bar + MTS_IRQ_MASK));

	/*
	 * v86: enable MT7531 PHY core PLL via C45 MMD 0x1f reg 0x403.  Our
	 * parent prelude reset the switch chip (BAR+0xf04), which destroys
	 * the bootloader's PLL state.  Without re-enabling here, the PHY
	 * can do AN handshake via MDIO but cannot generate a link signal.
	 * See mts_phy_pll_enable() comment + v85 result doc for the full
	 * diagnosis.
	 *
	 * v86 hardware: PLL was already on - this is a no-op write but kept
	 * for future hardware where the bootloader may not have set it.
	 */
	mts_phy_pll_enable(mts);

	/*
	 * v87: Orbis "unconditional tail" from mts_mac_init (post efuse-gated
	 * block).  The 4-agent v87 dig (deepseek + kimi + gpt5.5 + glm) all
	 * confirm these five C45 writes plus the C22 ANAR mask plus the BAR+0x04
	 * mask are what Orbis literally does after the MAC register setup, and
	 * we've been skipping them since v82.  Some of these writes target
	 * Realtek vendor registers that are no-ops on MT7531, but `0x3c0007`
	 * (MMD 7 reg 0x3c = ANEG-MMD) and the bit-clear in MMD 0x1e reg 0x330
	 * could be load-bearing.
	 */
	{
		u16 v16;

		/* C45 unconditional tail writes (verbatim from Orbis decompile). */
		mts_smi_c45_write(mts, 0x1e, 0x189, 0x110);
		mts_smi_c45_write(mts, 0x1e, 0x122, 0xffff);
		mts_smi_c45_write(mts, 0x1f, 0x268, 0x07f4);
		mts_smi_c45_write(mts, 0x07, 0x03c, 0x0000);
		if (mts_smi_c45_read(mts, 0x1e, 0x330, &v16) == 0) {
			mts_smi_c45_write(mts, 0x1e, 0x330, v16 & ~0x1000);
			dev_info(&mts->pdev->dev,
				 "v87 tail: MMD 0x1e reg 0x330 0x%04x -> 0x%04x (cleared bit 12)\n",
				 v16, v16 & ~0x1000);
		}

		/* C22 ANAR mask: clear bits 10-13 per Orbis. */
		if (mts_smi_c22_read(mts, 0x04, &v16) == 0) {
			mts_smi_c22_write(mts, 0x04, v16 & 0xf3ff);
			dev_info(&mts->pdev->dev,
				 "v87 tail: ANAR 0x%04x -> 0x%04x (mask 0xf3ff)\n",
				 v16, v16 & 0xf3ff);
		}

		/* BAR+0x04 R/M/W mask: clear bits 8-9 + 12-13 + 31.  Orbis does
		 * this TWICE in mts_mac_init (steps 34 and 47 per glm dig). */
		writel(readl(bar + MTS_LINK_STATUS) & 0x7fffcfff,
		       bar + MTS_LINK_STATUS);
		(void)readl(bar + MTS_LINK_STATUS);
		writel(readl(bar + MTS_LINK_STATUS) & 0x7fffcfff,
		       bar + MTS_LINK_STATUS);
		(void)readl(bar + MTS_LINK_STATUS);

		/*
		 * v88: MT7531 mainline DSP corrections + SlvDPSready Token-Ring
		 * fix.  Applied BETWEEN the Orbis tail (above) and the final AN
		 * restart (below) so the DSP is in a known-good state BEFORE
		 * 1000BT training begins.
		 *
		 * Five fixes from deepseek-v41's v88 fallback dig:
		 *
		 *   (a) Near-echo offset (MMD 0x1e reg 0xa6 bits 15:8 = 0x3)
		 *       Without this the echo canceller treats real reflections
		 *       as noise -> DSP can't converge.
		 *
		 *   (b) RX ADC bias (MMD 0x1e reg 0xc6 bits 9:8 = 0x3)
		 *       POR default has suboptimal bias -> distorted RX signal
		 *       -> training fails.
		 *
		 *   (c) 100M MSE threshold (MMD 0x1e reg 0x123 = 0xffff)
		 *       Default threshold is too tight -> rejects marginal
		 *       links that should work.
		 *
		 *   (d) SlvDPSready time = 0x5e (Token Ring write):
		 *       BOMBSHELL - Orbis's "Realtek pokes" accidentally land on
		 *       this TR register (ch=1 node=0xf data=0x17) writing
		 *       SlvDPSready=0x0c (12 ticks).  Mainline wants 0x5e (94).
		 *       Orbis's short timeout = slave DSP times out before it
		 *       finishes training -> master sees failure -> partner
		 *       asserts Remote Fault.  This is the most likely root
		 *       cause for the BMSR cycling we've seen since v82.
		 *       Read-modify-write to preserve other bits.
		 *
		 *   (e) EN_DOWNSHIFT (page 0x0001 reg 0x14 bit 4 = 1)
		 *       Lets PHY fall back to 100M after repeated 1000BT
		 *       training failures.  Defensive - not needed if (a)-(d)
		 *       make 1000BT training reliable, but cheap insurance.
		 *
		 *   (f) Bonus: stop advertising 1000BT (reg 9 &= ~0x0300)
		 *       Partner's reg 5 = 0xc5e1 doesn't include 1000BT anyway.
		 *       Removes 1000BT training entirely from the negotiation
		 *       path - the highest-confidence fix if (d) doesn't work.
		 *       Enabled by default; disable if you want to test (a)-(e)
		 *       in isolation.
		 */

		/* (a) Near-echo offset */
		if (mts_smi_c45_read(mts, 0x1e, 0xa6, &v16) == 0) {
			u16 nw = (v16 & 0x00ff) | 0x0300;
			mts_smi_c45_write(mts, 0x1e, 0xa6, nw);
			dev_info(&mts->pdev->dev,
				 "v88(a): near-echo MMD0x1e r0xa6: 0x%04x -> 0x%04x\n",
				 v16, nw);
		}

		/* (b) RX ADC bias */
		if (mts_smi_c45_read(mts, 0x1e, 0xc6, &v16) == 0) {
			u16 nw = (v16 & ~0x0300u) | 0x0300;
			mts_smi_c45_write(mts, 0x1e, 0xc6, nw);
			dev_info(&mts->pdev->dev,
				 "v88(b): RX ADC bias MMD0x1e r0xc6: 0x%04x -> 0x%04x\n",
				 v16, nw);
		}

		/* (c) 100M MSE threshold */
		mts_smi_c45_write(mts, 0x1e, 0x123, 0xffff);
		if (mts_smi_c45_read(mts, 0x1e, 0x123, &v16) == 0)
			dev_info(&mts->pdev->dev,
				 "v88(c): 100M MSE MMD0x1e r0x123 = 0x%04x\n", v16);

		/*
		 * (d) SlvDPSready TR write via page 0x52b5 + reg 0x10/0x11/0x12.
		 * READ-MODIFY-WRITE to preserve other bits in the 32-bit TR data.
		 *
		 * TR command encoding (per mtk-phy-lib.c):
		 *   bit 15: enable
		 *   bit 13: 1=read, 0=write
		 *   bits 11:10: channel (here 1, so 0x0400)
		 *   bits 9:6:  node (here 0xf, so 0x03c0)
		 *   bits 5:1:  data address (here 0x17, so 0x002e)
		 *
		 *   READ  cmd = 0x8000 | 0x2000 | 0x0400 | 0x03c0 | 0x002e = 0xafee
		 *   WRITE cmd = 0x8000 |    0   | 0x0400 | 0x03c0 | 0x002e = 0x8fee
		 *
		 * Wait — deepseek wrote 0x8fae in their analysis (and noted Orbis writes
		 * the same).  Let me check: their formula uses `(node << 7)` not
		 * `(node << 6)`.  And `(data << 1)` not `(data << 1)` — that part is
		 * the same.  The discrepancy:
		 *   deepseek: ((0xf & 0xf) << 7) | ((0x17 & 0x3f) << 1)
		 *           = 0x0780 | 0x002e = 0x07ae
		 *   mainline: ((node & 0xf) << 6) | ((daddr & 0x3f) << 1)?
		 *
		 * Going with deepseek's verified encoding (matches Orbis observed write):
		 *   tr_cmd_write = BIT(15) | ((1&3)<<11) | ((0xf&0xf)<<7) | ((0x17&0x3f)<<1)
		 *                = 0x8000 | 0x0800 | 0x0780 | 0x002e = 0x8fae
		 *   tr_cmd_read  = tr_cmd_write | BIT(13) = 0xafae
		 */
		{
			u16 saved_page;
			u16 tr_lo = 0, tr_hi = 0;
			u32 tr_val;

			/* Save current C22 page */
			mts_smi_c22_read(mts, 0x1f, &saved_page);

			/* Select Token Ring page */
			mts_smi_c22_write(mts, 0x1f, 0x52b5);

			/* Read existing SlvDPSready value */
			mts_smi_c22_write(mts, 0x10, 0xafae);  /* TR READ */
			mts_smi_c22_read(mts, 0x11, &tr_lo);
			mts_smi_c22_read(mts, 0x12, &tr_hi);
			tr_val = ((u32)tr_hi << 16) | tr_lo;

			dev_info(&mts->pdev->dev,
				 "v88(d): SlvDPSready TR read = 0x%08x (current SlvDPSready=0x%02x)\n",
				 tr_val, (tr_val >> 15) & 0xff);

			/* Set bits 22:15 to 0x5e (mainline value) */
			tr_val = (tr_val & ~(0xffu << 15)) | (0x5eu << 15);

			/* Write back */
			mts_smi_c22_write(mts, 0x11, tr_val & 0xffff);
			mts_smi_c22_write(mts, 0x12, (tr_val >> 16) & 0xffff);
			mts_smi_c22_write(mts, 0x10, 0x8fae);   /* TR WRITE */

			dev_info(&mts->pdev->dev,
				 "v88(d): SlvDPSready TR write = 0x%08x (SlvDPSready=0x5e)\n",
				 tr_val);

			/* Restore page */
			mts_smi_c22_write(mts, 0x1f, saved_page);
		}

		/* (e) EN_DOWNSHIFT — page 0x0001 reg 0x14 bit 4 = 1 */
		{
			u16 saved_page;
			u16 r14;

			mts_smi_c22_read(mts, 0x1f, &saved_page);
			mts_smi_c22_write(mts, 0x1f, 0x0001);
			if (mts_smi_c22_read(mts, 0x14, &r14) == 0) {
				mts_smi_c22_write(mts, 0x14, r14 | 0x0010);
				dev_info(&mts->pdev->dev,
					 "v88(e): EN_DOWNSHIFT page1 reg0x14: 0x%04x -> 0x%04x\n",
					 r14, r14 | 0x0010);
			}
			mts_smi_c22_write(mts, 0x1f, saved_page);
		}

		/* (f) Stop advertising 1000BT — defensive */
		if (mts_smi_c22_read(mts, 0x09, &v16) == 0) {
			mts_smi_c22_write(mts, 0x09, v16 & ~0x0300);
			dev_info(&mts->pdev->dev,
				 "v88(f): 1000BT_CTRL reg9: 0x%04x -> 0x%04x (no 1000BT advertise)\n",
				 v16, v16 & ~0x0300);
		}

		/*
		 * v89 (g): RGMII TX delay - mainline mt7531_phy_config_init sets
		 * these.  Originally deferred in v88 (deepseek said not link-critical
		 * for user port), but v88 hardware test showed PHY-level handshake
		 * succeeds yet MAC's BAR+0x04 bit 0 won't latch.  Suspicion: RGMII
		 * timing between Baikal MAC and MT7531 PHY is marginal at POR
		 * defaults, causing PHY's MAC-side RX to see corrupted data and
		 * never assert a stable LINK signal.
		 *
		 * MMD 0x1e reg 0x13 (MTK_PHY_GBE_MODE_TX_DELAY_SEL):
		 *   bits 10:8 = MTK_TX_DELAY_PAIR_B_MASK = 0x4
		 *   bits 2:0  = MTK_TX_DELAY_PAIR_D_MASK = 0x4
		 *   => 0x0404
		 *
		 * MMD 0x1e reg 0x14 (MTK_PHY_TEST_MODE_TX_DELAY_SEL): same value.
		 */
		if (mts_smi_c45_read(mts, 0x1e, 0x13, &v16) == 0) {
			u16 nw = (v16 & ~((0x7u << 8) | 0x7u)) | (0x4 << 8) | 0x4;
			mts_smi_c45_write(mts, 0x1e, 0x13, nw);
			dev_info(&mts->pdev->dev,
				 "v89(g): TX_DELAY r0x13: 0x%04x -> 0x%04x (PAIR_B=4 PAIR_D=4)\n",
				 v16, nw);
		}
		if (mts_smi_c45_read(mts, 0x1e, 0x14, &v16) == 0) {
			u16 nw = (v16 & ~((0x7u << 8) | 0x7u)) | (0x4 << 8) | 0x4;
			mts_smi_c45_write(mts, 0x1e, 0x14, nw);
			dev_info(&mts->pdev->dev,
				 "v89(g): TX_DELAY r0x14: 0x%04x -> 0x%04x (PAIR_B=4 PAIR_D=4)\n",
				 v16, nw);
		}

		/*
		 * v92 (h): clear MMD 0x1e reg 0x144 bit 5 (MTK_PHY_RG_TXEN_DIG_MASK).
		 * Mainline mtk-ge-soc.c:976-978 inside mt798x_phy_eee() does this
		 * for mt798x PHYs; MT7531 driver in mtk-ge.c never touches reg 0x144
		 * and assumes POR/efuse calibration clears the bit.  PS4 Baikal's
		 * Orbis driver does Realtek-page "magic pokes" that may stomp the
		 * bit back to 1, leaving the digital TX pre-driver gated.
		 * Phase 2 cable swap (2026-05-13) proved PHY can RX partner FLPs
		 * but is electrically not transmitting on the wire — host RTL8153
		 * sees NO-CARRIER.  TXEN_DIG=1 fits that exactly.
		 *
		 * Read first, log POR value, conditional clear: write only if bit
		 * 5 is already 1.  This avoids a useless clear of an already-clear
		 * bit AND lets the boot log tell us whether the bit was the cause.
		 *
		 * Verified against tmp/vanilla-6.15.4/drivers/net/phy/mediatek/
		 * mtk-ge-soc.c lines 205 (define 0x144), 206 (bit 5 mask),
		 * 976-978 (the clear call).
		 */
		if (mts_smi_c45_read(mts, 0x1e, 0x0144, &v16) == 0) {
			if (v16 & 0x0020) {
				u16 nw = v16 & ~0x0020;
				mts_smi_c45_write(mts, 0x1e, 0x0144, nw);
				dev_info(&mts->pdev->dev,
					 "v92(h): TXEN_DIG MMD0x1e r0x144 0x%04x -> 0x%04x (was bit5=1, now 0)\n",
					 v16, nw);
			} else {
				dev_info(&mts->pdev->dev,
					 "v92(h): TXEN_DIG MMD0x1e r0x144 = 0x%04x (bit5 already 0, no write)\n",
					 v16);
			}
		} else {
			dev_info(&mts->pdev->dev,
				 "v92(h): TXEN_DIG MMD0x1e r0x144 read FAILED\n");
		}

		/*
		 * FINAL AN restart per Orbis (BMCR |= 0x1200).  This is the LAST
		 * thing we do so AN starts training with all corrections applied.
		 */
		if (mts_smi_c22_read(mts, 0x00, &v16) == 0) {
			mts_smi_c22_write(mts, 0x00, v16 | 0x1200);
			dev_info(&mts->pdev->dev,
				 "v88 final: BMCR 0x%04x -> 0x%04x (AN restart after DSP corrections)\n",
				 v16, v16 | 0x1200);
		}
	}
}

/*
 * Generic PHY init for MT7531.  Phase-1 v77 boot proved Orbis's vendor-poke
 * pattern targets a Realtek-style page protocol — but the actual PHY here is
 * MediaTek MT7531 (ID 0x03a29441).  MT7531 has its own DSA-style switch
 * setup that mainline drives via drivers/net/dsa/mt7530-mdio.c; replicating
 * that is phase-2 work.  For phase-1b we just soft-reset the PHY's BMCR and
 * restart auto-negotiation — the PHY's defaults already advertise full GbE
 * capability (reg 9 = 0x0200 = adv 1000-BASE-T full).
 */
static int mts_phy_init(struct mts *mts)
{
	u16 bmcr;
	int i;

	mts_smi_c22_write(mts, 0x00, 0x8000); /* soft reset */
	for (i = 0; i < 100; i++) {
		if (mts_smi_c22_read(mts, 0x00, &bmcr))
			return -EIO;
		if (!(bmcr & 0x8000))
			break;
		usleep_range(1000, 2000);
	}
	if (bmcr & 0x8000) {
		dev_warn(&mts->pdev->dev, "PHY soft-reset did not clear\n");
		return -ETIMEDOUT;
	}
	mts_smi_c22_write(mts, 0x00, 0x1200); /* AN enable + restart */
	return 0;
}

static void mts_link_poll(struct timer_list *t)
{
	struct mts *mts = from_timer(mts, t, link_poll);
	u32 ls = readl(mts->bar + MTS_LINK_STATUS);
	u16 bmsr = 0xffff;

	mts_smi_c22_read(mts, 0x01, &bmsr);

	if (ls != mts->last_link || !mts->link_logged_once) {
		const char *speed = "?";

		if (ls & MTS_LINK_UP) {
			switch (ls & MTS_LINK_SPEED_MASK) {
			case MTS_LINK_SPEED_10:   speed = "10";   break;
			case MTS_LINK_SPEED_100:  speed = "100";  break;
			case MTS_LINK_SPEED_1000: speed = "1000"; break;
			}
			dev_info(&mts->pdev->dev,
				 "link UP — %s Mbps %s-duplex (linkreg=0x%08x, BMSR=0x%04x)\n",
				 speed,
				 (ls & MTS_LINK_FULL_DUPLEX) ? "full" : "half",
				 ls, bmsr);
		} else {
			dev_info(&mts->pdev->dev,
				 "link DOWN (linkreg=0x%08x, BMSR=0x%04x)\n",
				 ls, bmsr);
		}
		mts->last_link = ls;
		mts->link_logged_once = true;
	}

	mod_timer(&mts->link_poll, jiffies + HZ);
}

/*
 * v85 histogram ISR.  Replaces v84's stub with diagnostic recording:
 *   - Atomic histogram of unique irq_status patterns (up to 16 slots)
 *   - Linear scan finds slot, atomic_inc the counter
 *   - On first occurrence of a NEW pattern, logs it once (rare path)
 *   - Always W1C-acks BAR+0x50 then reads back
 *   - Logs every link-change IRQ (bit 2) with linkreg snapshot
 *
 * Histogram is dumped every 5s by mts_dbg_timer.  This gives us a
 * full picture of what the MAC is asserting without flooding dmesg.
 */
static irqreturn_t mts_intr(int irq, void *dev_id)
{
	struct mts *mts = dev_id;
	u32 status;
	int i;
	bool found = false;

	status = readl(mts->bar + MTS_IRQ_STATUS);
	if (!status)
		return IRQ_NONE;

	/* W1C-ack everything we saw, then read back to flush PCIe posted writes. */
	writel(status, mts->bar + MTS_IRQ_STATUS);
	(void)readl(mts->bar + MTS_IRQ_STATUS);

	atomic_inc(&mts->isr_total_count);

	/*
	 * v111: Orbis-style "exit init mode" handshake.  Per Ghidra
	 * mts_intr decompile + 2026-05-13 live userspace verification:
	 * when only the bit-18 (0x40000) IRQ fires (no other status bits),
	 * the MAC is signalling "I'm still in init mode, please finish the
	 * handshake".  Orbis responds by:
	 *   - writing 0 to BAR+0x204 (disable master IRQ block — releases
	 *     the MAC's internal init state machine to "operational" mode)
	 *   - restoring the saved IRQ mask to BAR+0x54
	 * Without this, RX engine bit 0 won't latch, BAR+0x04 bit 0
	 * (link-up) never sets, TX never completes.  Confirmed:
	 *   - v82..v110: bit-18 fires ~5kHz, MAC stuck → TX dead
	 *   - Userspace `writel(0, BAR+0x204)` halts bit-18 storm and
	 *     unmasks new IRQ patterns (just-bit-6 alone, never seen before)
	 * The handshake is one-shot per init (gated by irq_block_armed).
	 */
	if (mts->irq_block_armed &&
	    (status & ~mts->saved_irq_mask) == MTS_IRQ_BIT18) {
		mts->irq_block_armed = false;
		writel(0, mts->bar + MTS_IRQ_ENABLE_FULL);
		writel(mts->saved_irq_mask, mts->bar + MTS_IRQ_MASK);
		(void)readl(mts->bar + MTS_IRQ_MASK);
		/*
		 * v117: do NOT re-arm BAR+0x204 inline.  v112 did, which
		 * immediately retriggered bit-18 storm because re-arming
		 * after the chip has transitioned to "lockout" state only
		 * sets bit 28 and bit-18 keeps level-asserting.  Orbis's
		 * pattern re-enables BAR+0x204 in the next ISR's first-call
		 * setup; in our case, leaving 0x204=0 after the handshake
		 * stops the storm at the cost of no further MSIs from this
		 * ISR call.  TX/RX will need an alternate completion path
		 * (kthread heartbeat or polled NAPI) — separate v118+ work.
		 */
		dev_info(&mts->pdev->dev,
			 "v117: bit18 handshake cleared IRQ master — BAR+0x204=0x%08x BAR+0x54=0x%08x\n",
			 readl(mts->bar + MTS_IRQ_ENABLE_FULL),
			 readl(mts->bar + MTS_IRQ_MASK));
		return IRQ_HANDLED;
	}

	/* v93: schedule NAPI on RX/TX completion bits.  NAPI poll handles
	 * both directions; we don't mask IRQs here, level-triggered MSI is
	 * deasserted by the W1C above. */
	if (mts->ndev && (status & MTS_IRQ_NAPI_MASK)) {
		if (napi_schedule_prep(&mts->napi))
			__napi_schedule_irqoff(&mts->napi);
	}

	/* Histogram update — kept as debug aid for unhandled bits. */
	for (i = 0; i < MTS_ISR_HIST_SLOTS; i++) {
		if (READ_ONCE(mts->isr_hist_pattern[i]) == status) {
			atomic_inc(&mts->isr_hist_count[i]);
			found = true;
			break;
		}
		if (READ_ONCE(mts->isr_hist_pattern[i]) == 0) {
			WRITE_ONCE(mts->isr_hist_pattern[i], status);
			atomic_inc(&mts->isr_hist_count[i]);
			dev_info(&mts->pdev->dev,
				 "ISR: NEW pattern slot[%d] = 0x%08x (total=%d)\n",
				 i, status,
				 atomic_read(&mts->isr_total_count));
			found = true;
			break;
		}
	}
	if (!found && atomic_read(&mts->isr_total_count) < 100000) {
		dev_info_ratelimited(&mts->pdev->dev,
				     "ISR: irq_status=0x%08x (histogram full)\n",
				     status);
	}

	if (status & MTS_IRQ_LINK_CHANGE) {
		u32 linkreg = readl(mts->bar + MTS_LINK_STATUS);
		bool up = !!(linkreg & 0x1);

		atomic_inc(&mts->isr_link_change_count);
		dev_info(&mts->pdev->dev,
			 "ISR: link-change IRQ (irq_status=0x%08x, linkreg=0x%08x)\n",
			 status, linkreg);
		if (mts->ndev) {
			if (up && !netif_carrier_ok(mts->ndev))
				netif_carrier_on(mts->ndev);
			else if (!up && netif_carrier_ok(mts->ndev))
				netif_carrier_off(mts->ndev);
		}
	}
	return IRQ_HANDLED;
}

/*
 * v85 debug telemetry timer.  Dumps the ISR histogram and current BAR
 * state every MTS_DBG_TIMER_PERIOD_MS.  Logs linkreg only on change to
 * avoid spam, but always logs the histogram so we see IRQ rates over time.
 */
static void mts_dbg_timer_fn(struct timer_list *t)
{
	struct mts *mts = from_timer(mts, t, dbg_timer);
	u32 linkreg = readl(mts->bar + MTS_LINK_STATUS);
	u32 rxkick = readl(mts->bar + MTS_RX_KICK);
	u32 txkick = readl(mts->bar + MTS_TX_KICK);
	u32 irq_mask = readl(mts->bar + MTS_IRQ_MASK);
	u32 irq_status = readl(mts->bar + MTS_IRQ_STATUS);
	int total = atomic_read(&mts->isr_total_count);
	int i;

	dev_info(&mts->pdev->dev,
		 "DBG: linkreg=0x%08x rxkick=0x%08x txkick=0x%08x mask=0x%08x status=0x%08x total_irq=%d\n",
		 linkreg, rxkick, txkick, irq_mask, irq_status, total);

	for (i = 0; i < MTS_ISR_HIST_SLOTS; i++) {
		u32 p = READ_ONCE(mts->isr_hist_pattern[i]);
		int c = atomic_read(&mts->isr_hist_count[i]);

		if (p == 0 && c == 0)
			continue;
		dev_info(&mts->pdev->dev,
			 "DBG:   hist[%d] pattern=0x%08x count=%d\n",
			 i, p, c);
	}

	if (linkreg != mts->isr_last_linkreg) {
		dev_info(&mts->pdev->dev,
			 "DBG: ** linkreg changed 0x%08x -> 0x%08x **\n",
			 mts->isr_last_linkreg, linkreg);
		mts->isr_last_linkreg = linkreg;
	}

	mod_timer(&mts->dbg_timer,
		  jiffies + msecs_to_jiffies(MTS_DBG_TIMER_PERIOD_MS));
}

/*
 * AN restart sequence.  Mirrors Orbis FUN_c85f0480 event 0x1 handler exactly:
 * read 1000-BT control (reg 9) and ANAR (reg 4), OR-set the advertise bits if
 * not present, then write BMCR (reg 0) with bit 12 (AN enable) + bit 9 (AN
 * restart) set.  This is the "kick AN into action" sequence the Orbis driver
 * uses on every link-down event.
 *
 * Returns the post-restart BMCR for logging.
 */
static u16 mts_phy_an_restart(struct mts *mts)
{
	u16 ctrl_1000bt, anar, bmcr;

	mts_smi_c22_read(mts, 0x09, &ctrl_1000bt);
	mts_smi_c22_read(mts, 0x04, &anar);

	if (!(ctrl_1000bt & 0x0200))
		mts_smi_c22_write(mts, 0x09, ctrl_1000bt | 0x0200);
	if ((anar & 0x0180) != 0x0180)
		mts_smi_c22_write(mts, 0x04, anar | 0x0180);

	mts_smi_c22_read(mts, 0x00, &bmcr);
	mts_smi_c22_write(mts, 0x00, bmcr | 0x1200);
	return bmcr | 0x1200;
}

/*
 * SMI heartbeat + link bring-up thread.
 *
 * Two responsibilities:
 *   1) MDC heartbeat: every 3s the loop touches the SMI bus, which keeps the
 *      transaction-gated MDC clock domain alive.  v82 confirmed this is the
 *      sole way to prevent MDC death.
 *   2) Link bring-up: mirrors Orbis FUN_c85f0480 event 0x1 — on every UP->DOWN
 *      transition AND on the first iteration (initial bring-up from boot),
 *      run mts_phy_an_restart().  Retry every 5 iterations (~15s) while link
 *      stays down to handle AN that didn't latch the first time.  Stops
 *      retrying as soon as link comes up.
 *
 * Note: in Orbis the AN-restart is event-driven via mts_intr signaling
 * softc->event_phy_ctrl with bit 0x1.  We don't have an ISR yet (phase 3
 * work) so this thread polls linkreg directly.  Slightly more aggressive than
 * Orbis but correct in steady state.
 */
static int mts_phy_ctrl_fn(void *data)
{
	struct mts *mts = data;
	u32 linkreg, prev_linkreg = ~0U;
	u16 bmsr1, bmsr2;
	u16 prev_bmsr2 = 0xffff;
	bool link_up, was_up;
	int ret;

	while (!kthread_should_stop()) {
		linkreg = readl(mts->bar + MTS_LINK_STATUS);
		link_up = (linkreg & MTS_LINK_UP) != 0;
		was_up = mts->last_phy_link_up;

		/* v85: log linkreg whenever it changes - even if bit 0 unchanged. */
		if (linkreg != prev_linkreg) {
			dev_info(&mts->pdev->dev,
				 "phy_ctrl: linkreg changed 0x%08x -> 0x%08x\n",
				 prev_linkreg, linkreg);
			prev_linkreg = linkreg;
		}

		if (link_up && !was_up) {
			dev_info(&mts->pdev->dev,
				 "phy_ctrl: link UP (linkreg=0x%08x)\n",
				 linkreg);
			mts->link_down_iterations = 0;
		}
		if (!link_up && was_up) {
			dev_info(&mts->pdev->dev,
				 "phy_ctrl: link DOWN (linkreg=0x%08x)\n",
				 linkreg);
		}
		mts->last_phy_link_up = link_up;

		/*
		 * v85: read BMSR TWICE.  Bit 2 (link status) is latch-low: first
		 * read returns latched-low value, second read returns current.
		 * If bmsr1 != bmsr2 with bit 2 differing, link IS up at PHY but
		 * MAC isn't latching it - that pinpoints the disconnect.
		 */
		ret = mts_smi_c22_read(mts, 0x01, &bmsr1);
		if (ret == 0) {
			ret = mts_smi_c22_read(mts, 0x01, &bmsr2);
			if (ret == 0 && (bmsr1 != bmsr2 ||
					 bmsr2 != prev_bmsr2)) {
				dev_info(&mts->pdev->dev,
					 "phy_ctrl: BMSR latch=0x%04x current=0x%04x (link@phy=%d AN@phy=%d)\n",
					 bmsr1, bmsr2,
					 !!(bmsr2 & 0x0004),
					 !!(bmsr2 & 0x0020));
				prev_bmsr2 = bmsr2;
			}
		}

		/*
		 * v87 diagnostic: read PHY reg 5 (LP ABILITY) and reg 10
		 * (1000BT status) every iteration; log when they change.  Per
		 * deepseek-v41: reg 5 bit 13 = REMOTE FAULT.  Per glm/RE doc:
		 * reg 10 bit 13 = M/S config fault.  Watching these tells us
		 * whether the partner keeps asserting RF or M/S resolution
		 * is failing.
		 */
		{
			u16 lpa = 0xffff, s1g = 0xffff;
			static u16 prev_lpa = 0xffff, prev_s1g = 0xffff;

			if (mts_smi_c22_read(mts, 0x05, &lpa) == 0 &&
			    lpa != prev_lpa) {
				dev_info(&mts->pdev->dev,
					 "phy_ctrl: LP ABILITY (reg5)=0x%04x (RF=%d ACK=%d 100TX_FD=%d 100TX=%d 10T_FD=%d 10T=%d)\n",
					 lpa,
					 !!(lpa & 0x2000),
					 !!(lpa & 0x4000),
					 !!(lpa & 0x0100),
					 !!(lpa & 0x0080),
					 !!(lpa & 0x0040),
					 !!(lpa & 0x0020));
				prev_lpa = lpa;
			}
			if (mts_smi_c22_read(mts, 0x0a, &s1g) == 0 &&
			    s1g != prev_s1g) {
				dev_info(&mts->pdev->dev,
					 "phy_ctrl: 1000BT_STAT (reg10)=0x%04x (MS_FAULT=%d MS_CFG=%d L_RX_OK=%d R_RX_OK=%d LP_FD=%d LP_HD=%d)\n",
					 s1g,
					 !!(s1g & 0x8000),
					 !!(s1g & 0x4000),
					 !!(s1g & 0x2000),
					 !!(s1g & 0x1000),
					 !!(s1g & 0x0800),
					 !!(s1g & 0x0400));
				prev_s1g = s1g;
			}
		}

		if (!link_up) {
			bool first = !mts->initial_an_done;
			bool transition = was_up;
			/*
			 * v87: REMOVED periodic AN restart.  v86 hardware showed
			 * BMSR oscillating between 0x7949 / 0x7969 because we
			 * restart AN every 15s before link can stabilize.  Now
			 * only restart on (a) very first iteration (initial
			 * bring-up) or (b) UP -> DOWN transition.  Let the PHY
			 * complete AN naturally and observe partner RF behavior.
			 */
			if (first || transition) {
				u16 bmcr_post = mts_phy_an_restart(mts);
				dev_info(&mts->pdev->dev,
					 "phy_ctrl: AN restart (iter=%u, BMCR<-0x%04x, reason=%s)\n",
					 mts->link_down_iterations, bmcr_post,
					 first ? "first" : "down_transition");
				mts->initial_an_done = true;
			}
			mts->link_down_iterations++;
		}

		/*
		 * v94: PHY-derived carrier detection.  v93 boot proved the MAC's
		 * BAR+0x04 bit 0 doesn't always latch even when the PHY-level
		 * link is fully healthy (AN done, both receivers OK, partner
		 * ACK).  When that bit fails to latch the link-change IRQ never
		 * fires, the ISR never calls netif_carrier_on, and Linux refuses
		 * to call ndo_start_xmit -> all packets get dropped at the qdisc
		 * layer.
		 *
		 * Workaround: trust the PHY directly.  If BMSR bit 5 (AN done)
		 * AND reg 5 bit 14 (partner ACK) are both set, the partner has
		 * acknowledged us at the AN layer and the link is functionally
		 * up — even if the MAC's status bit hasn't latched.  Toggle
		 * netif_carrier from this thread so userspace can use the
		 * interface.  Re-checked every 3s with the existing heartbeat.
		 */
		{
			u16 v_bmsr = 0xffff, v_lpa = 0xffff;
			bool phy_carrier;

			if (mts->ndev &&
			    mts_smi_c22_read(mts, 0x01, &v_bmsr) == 0 &&
			    mts_smi_c22_read(mts, 0x05, &v_lpa) == 0) {
				phy_carrier = (v_bmsr & 0x0020) &&
					      (v_lpa & 0x4000);
				/* v95: compare against the actual netdev carrier
				 * state instead of an internal cache.  Reason:
				 * ndo_open in v93 unconditionally calls
				 * netif_carrier_off when linkreg bit 0 is 0,
				 * which would overwrite an already-set carrier.
				 * Using netif_carrier_ok() lets us detect that
				 * override and re-assert on the next tick. */
				if (phy_carrier != netif_carrier_ok(mts->ndev)) {
					if (phy_carrier) {
						netif_carrier_on(mts->ndev);
						dev_info(&mts->pdev->dev,
							 "v94/v95: netif_carrier_on (PHY-level: BMSR=0x%04x LPA=0x%04x)\n",
							 v_bmsr, v_lpa);
					} else {
						netif_carrier_off(mts->ndev);
						dev_info(&mts->pdev->dev,
							 "v94/v95: netif_carrier_off (BMSR=0x%04x LPA=0x%04x)\n",
							 v_bmsr, v_lpa);
					}
				}
				mts->last_phy_carrier = phy_carrier;
			}
		}

		msleep_interruptible(MTS_PHY_CTRL_PERIOD_MS);
	}
	return 0;
}

/* ===================================================================
 * v93: netdev wrapper — ndo_open / ndo_stop / ndo_start_xmit / NAPI poll.
 *
 * Descriptor layout, ownership semantics, kick registers, and IRQ bits
 * all confirmed via hermes Ghidra dig of Orbis 12.02 mts_init_rings_kick
 * + mts_tx_complete + mts_rx_process + mts_rx_unwrap_one + mts_intr.
 * =================================================================== */

static void mts_rx_release_one(struct mts *mts, unsigned int i)
{
	if (mts->rx_skb[i]) {
		dma_unmap_single(&mts->pdev->dev, mts->rx_dma[i],
				 MTS_RX_BUF_SIZE, DMA_FROM_DEVICE);
		dev_kfree_skb_any(mts->rx_skb[i]);
		mts->rx_skb[i] = NULL;
		mts->rx_dma[i] = 0;
	}
}

/*
 * Pre-fill an RX descriptor slot.  Per hermes mts_init_rings_kick:
 *   ctl_len = 0x00000600 (length, OWN=0 to give to HW)
 *   plus WRAP bit if this is the last entry
 * Driver clears OWN bit to hand to HW; HW will set OWN bit on completion.
 */
static int mts_rx_alloc(struct mts *mts, unsigned int i)
{
	struct sk_buff *skb;
	dma_addr_t dma;
	u32 ctl_len;

	skb = netdev_alloc_skb_ip_align(mts->ndev, MTS_RX_BUF_SIZE);
	if (!skb)
		return -ENOMEM;

	dma = dma_map_single(&mts->pdev->dev, skb->data, MTS_RX_BUF_SIZE,
			     DMA_FROM_DEVICE);
	if (dma_mapping_error(&mts->pdev->dev, dma)) {
		dev_kfree_skb_any(skb);
		return -ENOMEM;
	}

	mts->rx_skb[i] = skb;
	mts->rx_dma[i] = dma;

	ctl_len = MTS_RX_BUF_SIZE;	/* OWN=0 → HW takes ownership */
	if (i == MTS_NUM_RX_DESC - 1)
		ctl_len |= MTS_DESC_WRAP;

	mts->rx_ring[i].buf_lo = cpu_to_le32(lower_32_bits(dma));
	mts->rx_ring[i].aux0   = 0;
	mts->rx_ring[i].aux1   = 0;
	/* ctl_len last, with dma_wmb so address+aux are visible first */
	dma_wmb();
	mts->rx_ring[i].ctl_len = cpu_to_le32(ctl_len);
	return 0;
}

/*
 * Initialize both rings.  Per hermes mts_init_rings_kick:
 *  - TX descriptors start as "free" with OWN=1 + aux0 sentinel 0xffff0000.
 *  - RX descriptors built then OWN cleared to hand to HW.
 */
static void __maybe_unused mts_rings_init(struct mts *mts)
{
	unsigned int i;

	memset(mts->tx_ring_virt, 0, MTS_RING_BYTES);
	memset(mts->rx_ring_virt, 0, MTS_RING_BYTES);
	memset(mts->tx_skb, 0, sizeof(mts->tx_skb));
	memset(mts->rx_skb, 0, sizeof(mts->rx_skb));
	memset(mts->tx_dma, 0, sizeof(mts->tx_dma));
	memset(mts->rx_dma, 0, sizeof(mts->rx_dma));
	mts->tx_prod = 0;
	mts->tx_cons = 0;
	mts->rx_head = 0;

	for (i = 0; i < MTS_NUM_TX_DESC; i++) {
		u32 ctl_len = MTS_DESC_OWN;	/* OWN=1 = free (CPU-owned) */

		if (i == MTS_NUM_TX_DESC - 1)
			ctl_len |= MTS_DESC_WRAP;
		mts->tx_ring[i].ctl_len = cpu_to_le32(ctl_len);
		mts->tx_ring[i].aux0    = cpu_to_le32(MTS_DESC_TX_AUX0_FREE);
	}

	for (i = 0; i < MTS_NUM_RX_DESC; i++) {
		if (mts_rx_alloc(mts, i)) {
			dev_warn(&mts->pdev->dev,
				 "v93: RX prefill failed at %u/%u\n",
				 i, MTS_NUM_RX_DESC);
			break;
		}
	}
}

static void mts_rings_release(struct mts *mts)
{
	unsigned int i;

	for (i = 0; i < MTS_NUM_RX_DESC; i++)
		mts_rx_release_one(mts, i);

	for (i = 0; i < MTS_NUM_TX_DESC; i++) {
		if (mts->tx_skb[i]) {
			dma_unmap_single(&mts->pdev->dev, mts->tx_dma[i],
					 mts->tx_skb[i]->len, DMA_TO_DEVICE);
			dev_kfree_skb_any(mts->tx_skb[i]);
			mts->tx_skb[i] = NULL;
		}
	}
}

static int mts_open(struct net_device *ndev)
{
	struct mts *mts = netdev_priv(ndev);
	unsigned int i;
	u32 tx_ctrl_before, rx_ctrl_before;
	int link_wait;
	int ret;
	u16 id1 = 0xffff, id2 = 0xffff;

	/*
	 * v105: full MAC + PHY init moved from probe to ndo_open per
	 * hermes/kimi/glm convergent recommendation.  Orbis calls
	 * mts_mac_init from mts_ifup (open path), not just mts_attach
	 * (probe).  The MAC's one-shot link-status latch evaluates
	 * during the fresh MAC bring-up — by the time probe-time mac_init
	 * runs in v97+, the latch window misses the PHY-up moment.
	 * Running mac_init here, with PHY likely already linked from
	 * v94 kthread carrier state, should latch BAR+0x04 bit 0.
	 *
	 * v82-v89 PHY tweaks (SlvDPSready TR write, RGMII delays, etc.)
	 * happen INSIDE mts_mac_init, so they re-run on every open which
	 * is exactly what Orbis does.
	 */
	synchronize_irq(mts->irq);
	netif_carrier_off(ndev);

	mts_parent_prelude(mts);
	mts_mac_init(mts);

	mts_smi_c22_read(mts, 0x02, &id1);
	mts_smi_c22_read(mts, 0x03, &id2);
	dev_info(&mts->pdev->dev,
		 "v105: mts_mac_init done in ndo_open: BAR+0x04=0x%08x PHY ID=%04x:%04x\n",
		 readl(mts->bar + MTS_LINK_STATUS), id1, id2);

	ret = mts_phy_init(mts);
	if (ret)
		dev_warn(&mts->pdev->dev,
			 "v105: PHY init failed (%d) — link may not come up\n",
			 ret);

	/*
	 * v104: re-arm the MAC's one-shot link-bit-0 latch by recreating
	 * the v91 cold-start timing inside ndo_open.
	 *
	 * Background (hermes/kimi/deepseek convergent diagnosis, v99-v102):
	 * BAR+0x06c bit 9 is a HW-set "TX DMA ready" status.  It gates
	 * open only when BAR+0x04 bit 0 latches to 1.  Bit 0 latch is
	 * one-shot, evaluated during the RX-engine STOPPED→RUNNING
	 * transition; if RX descriptors are present at that moment,
	 * the scheduler immediately enters "datapath active" mode and
	 * permanently skips link sampling.  v91 worked because RX ring
	 * was empty during engine start; v97+ broke it by pre-filling
	 * RX before engine restart.
	 *
	 * v104 fix: in ndo_open, STOP engines, ZERO rings, START engines
	 * with empty rings (re-opens latch window per v91 timing), wait
	 * for AN+latch, THEN populate RX descriptors with real SKBs.
	 */
	synchronize_irq(mts->irq);

	tx_ctrl_before = readl(mts->bar + MTS_TX_CTRL);
	rx_ctrl_before = readl(mts->bar + MTS_RX_CTRL);

	/* 1. Stop engines. */
	writel(tx_ctrl_before & ~0x1u, mts->bar + MTS_TX_CTRL);
	writel(rx_ctrl_before & ~0x1u, mts->bar + MTS_RX_CTRL);
	(void)readl(mts->bar + MTS_TX_CTRL);
	mdelay(5);

	/* 2. Zero the rings (= v91 empty state).  Do NOT call
	 * mts_rings_init yet — that pre-fills RX with SKBs which is
	 * what broke v97+.  Just memset and re-program base addresses. */
	memset(mts->tx_ring_virt, 0, MTS_RING_BYTES);
	memset(mts->rx_ring_virt, 0, MTS_RING_BYTES);
	memset(mts->tx_skb, 0, sizeof(mts->tx_skb));
	memset(mts->rx_skb, 0, sizeof(mts->rx_skb));
	memset(mts->tx_dma, 0, sizeof(mts->tx_dma));
	memset(mts->rx_dma, 0, sizeof(mts->rx_dma));
	mts->tx_prod = 0;
	mts->tx_cons = 0;
	mts->rx_head = 0;

	writel(lower_32_bits(mts->tx_ring_dma), mts->bar + MTS_TX_DESC_LO);
	writel(lower_32_bits(mts->tx_ring_dma), mts->bar + MTS_TX_DESC_HI);
	writel(lower_32_bits(mts->rx_ring_dma), mts->bar + MTS_RX_DESC_LO);
	writel(lower_32_bits(mts->rx_ring_dma), mts->bar + MTS_RX_DESC_HI);

	dev_info(&mts->pdev->dev,
		 "v104: ndo_open engine-restart with EMPTY rings (TX 0x%08x->0x%08x RX 0x%08x->0x%08x)\n",
		 tx_ctrl_before, readl(mts->bar + MTS_TX_CTRL),
		 rx_ctrl_before, readl(mts->bar + MTS_RX_CTRL));

	/* 3. Start engines with empty rings → MAC's link-detect state
	 *    machine samples PHY MII status now (no datapath work yet).
	 *
	 * v126: Orbis Ghidra dump confirms TX_CTRL (BAR+0x034) needs
	 * persistent config bits 8+16 (= 0x00010100) before the bit-0 "go"
	 * pulse is honoured.  Without those bits, HW accepts the go bit
	 * (auto-clears it) but never starts the TX DMA fetch.  v82..v125
	 * only wrote bit 0; v125 BAR0 telemetry confirmed TX current
	 * pointer (BAR+0x03c) never advanced past base — i.e. zero
	 * descriptors fetched across 22 xmit attempts.
	 *
	 * Why Linux missed this: mts_mac_init writes 0x00010100 to BAR+0x030
	 * (MTS_MAC_MODE) already, and BAR+0x030 / 0x034 are visible at the
	 * same value in the Orbis idle snapshot — we assumed they aliased.
	 * They don't: 0x030 is MAC_MODE config; 0x034 is the TX engine
	 * control register and needs its own programming.  See Ghidra
	 * decompile of Orbis mts_mac_init @ 0xffffffffc85ecb60 (writes
	 * 0x10100 to 0x030) and mts_init_rings_kick @ 0xffffffffc85ef1b0
	 * (ORs bit 0 to 0x034) — Orbis must also write 0x10100 to 0x034
	 * somewhere we haven't yet localised, since the snapshot shows
	 * both registers at 0x00010100 in working state.
	 *
	 * Write cfg bits + go bit in one transaction.  After this write the
	 * read-back should show 0x00010100 (HW clears go, cfg persists).
	 * Same RX_CTRL pattern is left as-is since RX already works. */
	{
		u32 tx_before = readl(mts->bar + MTS_TX_CTRL);
		u32 tx_after;

		writel(tx_before | 0x00010101u, mts->bar + MTS_TX_CTRL);
		tx_after = readl(mts->bar + MTS_TX_CTRL);
		dev_info(&mts->pdev->dev,
			 "v126: TX_CTRL 0x%08x -> writel(|0x10101) -> 0x%08x (Orbis cfg bits 8+16 + go)\n",
			 tx_before, tx_after);
	}
	writel(readl(mts->bar + MTS_RX_CTRL) | 0x1, mts->bar + MTS_RX_CTRL);

	/*
	 * v110: BAR+0x1c8 |= 0x40 (clear bits 6+10, then set bit 6).  Orbis
	 * mts_init_rings_kick @ 0xffffffffc85ef1b0 does this as its final
	 * action — the function checks bit 6 at entry and bails if set,
	 * so bit 6 is the driver's "rings have been kicked" semaphore.
	 * Our driver never wrote it, which may leave the device in a
	 * state where TX engine never observes "rings ready" → TX dead.
	 * Mirrors Orbis: BAR+0x1c8 = (current & 0xfffffbbf) | 0x40.
	 */
	{
		u32 v1c8_before = readl(mts->bar + MTS_MCAST_MASK);
		u32 mask_before, mask_after;

		writel((v1c8_before & ~0x440u) | 0x40u, mts->bar + MTS_MCAST_MASK);
		dev_info(&mts->pdev->dev,
			 "v110: BAR+0x1c8 0x%08x -> 0x%08x (rings-ready marker per Orbis)\n",
			 v1c8_before, readl(mts->bar + MTS_MCAST_MASK));

		/*
		 * v115: gbe:ctrl completion emulation.  Orbis ctrl path clears
		 * BAR+0x54 bit12 after mts_init_rings_kick / link/RMU handling.
		 * Do it immediately after our ring-kick marker too, so the MAC
		 * sees the completion edge even before the first bit18 IRQ race.
		 */
		mask_before = readl(mts->bar + MTS_IRQ_MASK);
		mask_after = mask_before & ~MTS_IRQ_CTRL_DONE_BIT;
		writel(mask_after, mts->bar + MTS_IRQ_MASK);
		dev_info(&mts->pdev->dev,
			 "v115: gbe:ctrl-done BAR+0x54 0x%08x -> 0x%08x (clear bit12)\n",
			 mask_before, readl(mts->bar + MTS_IRQ_MASK));

		/*
		 * v117: Orbis enables the BAR+0x204 master IRQ block lazily
		 * from mts_intr after mts_init_rings_kick has set BAR+0x54 and
		 * reset softc+0x309c.  In Linux we have no pre-existing IRQ
		 * entry point with the master disabled, so emulate that
		 * first-call enable here — AFTER engines/rings/bit-12 clear
		 * are in place.  This is the "fresh-init" state where the
		 * chip accepts the full 0x10001388 (all bits stick).  The
		 * bit-18 handler then clears master cleanly without storm.
		 */
		mts->saved_irq_mask = mask_after;
		mts->irq_block_armed = true;
		writel(MTS_IRQ_ENABLE_FULL_VAL, mts->bar + MTS_IRQ_ENABLE_FULL);
		dev_info(&mts->pdev->dev,
			 "v117: post-ring IRQ enable BAR+0x204=0x%08x BAR+0x54=0x%08x\n",
			 readl(mts->bar + MTS_IRQ_ENABLE_FULL),
			 readl(mts->bar + MTS_IRQ_MASK));
	}

	/* 4. Wait for MAC bit 0 latch.  v91 took ~5s from engine start
	 *    + kthread AN restart.  Poll BAR+0x04 bit 0 with timeout. */
	for (link_wait = 0; link_wait < 100; link_wait++) {
		if (readl(mts->bar + MTS_LINK_STATUS) & 0x1)
			break;
		msleep(50);
	}
	dev_info(&mts->pdev->dev,
		 "v104: post engine-start wait %dms: linkreg=0x%08x bar06c=0x%08x\n",
		 link_wait * 50,
		 readl(mts->bar + MTS_LINK_STATUS),
		 readl(mts->bar + 0x06c));

	/* 5. NOW populate RX descriptors with real SKBs.  HW already
	 *    sampled link state during the empty-ring engine start.
	 *    From here on, RX descriptors get OWN=0 + buf_lo, HW writes
	 *    incoming packets normally (v97 path). */
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
				 "v104: RX populate failed at %u\n", i);
			break;
		}
	}

	napi_enable(&mts->napi);
	netif_start_queue(ndev);

	/* Re-kick RX so HW picks up the now-populated ring (was empty
	 * during the latch window). */
	writel(readl(mts->bar + MTS_RX_CTRL) | MTS_KICK_PKT,
	       mts->bar + MTS_RX_CTRL);

	/* Diagnostic: log first 2 RX descriptors + ring DMA addresses
	 * + BAR ring-base readbacks so the boot log proves descriptor
	 * setup is correct (or pinpoints the divergence). */
	dev_info(&mts->pdev->dev,
		 "v97: rx_ring_dma=%pad bar040=0x%08x bar048=0x%08x | rx[0] ctl=0x%08x buf=0x%08x | rx[1] ctl=0x%08x buf=0x%08x\n",
		 &mts->rx_ring_dma,
		 readl(mts->bar + MTS_RX_DESC_LO),
		 readl(mts->bar + MTS_RX_DESC_HI),
		 le32_to_cpu(mts->rx_ring[0].ctl_len),
		 le32_to_cpu(mts->rx_ring[0].buf_lo),
		 le32_to_cpu(mts->rx_ring[1].ctl_len),
		 le32_to_cpu(mts->rx_ring[1].buf_lo));

	dev_info(&mts->pdev->dev,
		 "v93: ndo_open %s tx_ring=%pad rx_ring=%pad\n",
		 ndev->name, &mts->tx_ring_dma, &mts->rx_ring_dma);

	/* v95: only set carrier_on here if the MAC has actually latched
	 * link bit 0.  Do NOT call netif_carrier_off — the phy_ctrl
	 * kthread owns the PHY-derived carrier state (see v94), and
	 * unconditionally clearing it here races with the kthread cache. */
	if (readl(mts->bar + MTS_LINK_STATUS) & 0x1)
		netif_carrier_on(ndev);

	/* v103: trigger fresh PHY auto-negotiation from ndo_open AFTER
	 * engines are running and RX descriptors are fully primed.
	 *
	 * Rationale (hermes/kimi/deepseek convergent finding, 2026-05-13):
	 * MAC's BAR+0x04 bit 0 link-up latch is a ONE-SHOT, edge-triggered
	 * on internal PCS/RGMII link tuple transition (0 → up).  In v91
	 * boot (no netdev), kthread's first AN restart fired AT t~=5s, MAC
	 * saw the resulting PHY link transition, and bit 0 latched
	 * (linkreg=0xb19).  In v97+ boots, kthread fires same AN restart
	 * BUT the latch window is then disturbed by ndo_open's engine
	 * reset and RX ring pre-fill — by the time ndo_open completes
	 * with real descriptors, the one-shot window has expired and MAC
	 * has decided "no link" permanently.  No subsequent PHY/MAC event
	 * gets bit 0 to latch.
	 *
	 * Without bit 0 latched, BAR+0x06c bit 9 (HW-driven "TX DMA
	 * ready" status) stays 0 — the TX engine refuses to fetch
	 * descriptors despite correct format, valid kick.  Result: TX
	 * dropped 100% with descriptors stranded in DMA memory.
	 *
	 * Replicate the Orbis gbe:phy_ctrl event-1 recovery sequence:
	 *  - reg9 (1000BT_CTRL) |= 0x0200 (re-advertise 1000T half)
	 *  - reg4 (ANAR) |= 0x0180 (assert pause + 100full)
	 *  - BMCR (reg0) |= 0x1200 (AN enable + restart)
	 * which generates a fresh PHY base page → partner ACKs → MAC's
	 * internal link state machine sees a new transition → bit 2
	 * LINK_CHANGE IRQ fires → bit 0 of 0x04 latches → bit 9 of 0x06c
	 * gates open → TX engine fetches descriptors.
	 *
	 * Verified live (2026-05-13): bit 9 of 0x06c is HW-status only,
	 * untouchable by direct writes.  Only path to set it is via the
	 * MAC's natural link-up event.
	 */
	{
		u16 v16;

		if (mts_smi_c22_read(mts, 0x09, &v16) == 0)
			mts_smi_c22_write(mts, 0x09, v16 | 0x0200);
		if (mts_smi_c22_read(mts, 0x04, &v16) == 0)
			mts_smi_c22_write(mts, 0x04, v16 | 0x0180);
		if (mts_smi_c22_read(mts, 0x00, &v16) == 0) {
			mts_smi_c22_write(mts, 0x00, v16 | 0x1200);
			dev_info(&mts->pdev->dev,
				 "v103: ndo_open AN restart BMCR 0x%04x -> 0x%04x (provoke fresh link-change for MAC bit 0 latch)\n",
				 v16, v16 | 0x1200);
		}
	}

	return 0;
}

static int mts_stop(struct net_device *ndev)
{
	struct mts *mts = netdev_priv(ndev);

	netif_stop_queue(ndev);
	netif_carrier_off(ndev);
	napi_disable(&mts->napi);

	/* Do NOT stop MAC engines — link UP depends on them running.
	 * (deepseek-v84 finding.)  Subsequent ndo_open re-uses the
	 * still-active engines + reinitialized rings. */

	mts_rings_release(mts);

	dev_info(&mts->pdev->dev, "v93: ndo_stop %s\n", ndev->name);
	return 0;
}

/*
 * TX submit.  Per hermes mts_tx_complete + FUN_c85f1aa0:
 *  - Free descriptor: OWN=1, aux0 has sentinel 0xffff0000.
 *  - Driver clears OWN (sets OWN=0) and clears aux0 sentinel — but ONLY
 *    AFTER writing buf_lo + aux0/aux1.  Last write is ctl_len with
 *    SOF|EOF|len|WRAP? and OWN=0.
 *  - Kick: BAR+0x34 |= 4.
 *  - HW completion: HW sets OWN=1 back; aux0 still 0 (not sentinel).
 */
static netdev_tx_t mts_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct mts *mts = netdev_priv(ndev);
	unsigned int entry;
	dma_addr_t dma;
	u32 ctl_len;
	unsigned long flags;

	dev_info_ratelimited(&mts->pdev->dev,
			     "v97 xmit: len=%u tx_prod=%u tx_cons=%u\n",
			     skb->len, mts->tx_prod, mts->tx_cons);

	if (unlikely(skb_put_padto(skb, ETH_ZLEN)))
		return NETDEV_TX_OK;

	if (unlikely(skb->len > MTS_TX_BUF_MAX)) {
		ndev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	spin_lock_irqsave(&mts->tx_lock, flags);

	entry = mts->tx_prod & (MTS_NUM_TX_DESC - 1);
	if (unlikely(mts->tx_skb[entry])) {
		netif_stop_queue(ndev);
		spin_unlock_irqrestore(&mts->tx_lock, flags);
		return NETDEV_TX_BUSY;
	}

	dma = dma_map_single(&mts->pdev->dev, skb->data, skb->len,
			     DMA_TO_DEVICE);
	if (dma_mapping_error(&mts->pdev->dev, dma)) {
		spin_unlock_irqrestore(&mts->tx_lock, flags);
		ndev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	mts->tx_skb[entry] = skb;
	mts->tx_dma[entry] = dma;

	/* SOF + EOF for single-fragment frame, length in low 16 bits.
	 * OWN=0 — driver hands to HW. */
	ctl_len = MTS_DESC_TX_SOF | MTS_DESC_TX_EOF | (skb->len & 0xffff);
	if (entry == MTS_NUM_TX_DESC - 1)
		ctl_len |= MTS_DESC_WRAP;

	mts->tx_ring[entry].buf_lo = cpu_to_le32(lower_32_bits(dma));
	mts->tx_ring[entry].aux0   = 0;
	mts->tx_ring[entry].aux1   = 0;
	dma_wmb();
	/* ctl_len last with OWN=0; this is the hand-off to HW. */
	mts->tx_ring[entry].ctl_len = cpu_to_le32(ctl_len);
	dma_wmb();

	mts->tx_prod++;

	/* TX kick — bit 2 of BAR+0x34 (TX CTRL register). */
	writel(readl(mts->bar + MTS_TX_CTRL) | MTS_KICK_PKT,
	       mts->bar + MTS_TX_CTRL);

	/* v98: rate-limited TX descriptor dump after submit + kick.
	 * Proves what bytes HW will see when it scans the ring. */
	dev_info_ratelimited(&mts->pdev->dev,
		"v98 xmit[%u] desc: ctl=0x%08x buf=0x%08x a0=0x%08x a1=0x%08x | tx_ctrl=0x%08x base=0x%08x pair=0x%08x\n",
		entry,
		le32_to_cpu(mts->tx_ring[entry].ctl_len),
		le32_to_cpu(mts->tx_ring[entry].buf_lo),
		le32_to_cpu(mts->tx_ring[entry].aux0),
		le32_to_cpu(mts->tx_ring[entry].aux1),
		readl(mts->bar + MTS_TX_CTRL),
		readl(mts->bar + MTS_TX_DESC_LO),
		readl(mts->bar + MTS_TX_DESC_HI));

	spin_unlock_irqrestore(&mts->tx_lock, flags);
	return NETDEV_TX_OK;
}

/* Reap completed TX descriptors.  HW sets OWN=1 on a non-sentinel descriptor
 * to indicate completion (per hermes mts_tx_complete decompile). */
static int mts_tx_reap(struct mts *mts, int budget)
{
	int done = 0;
	unsigned long flags;
	static u32 reap_call_count;

	spin_lock_irqsave(&mts->tx_lock, flags);

	/* v98: log first descriptor state every 100 reap calls — see if HW
	 * ever sets OWN=1 on entry 0 (= TX completion). */
	if ((reap_call_count++ % 100) == 0 && mts->tx_prod != mts->tx_cons) {
		u32 ctl0 = le32_to_cpu(READ_ONCE(mts->tx_ring[0].ctl_len));
		u32 a0_0 = le32_to_cpu(READ_ONCE(mts->tx_ring[0].aux0));
		dev_info(&mts->pdev->dev,
			"v98 reap probe: tx_prod=%u tx_cons=%u rx[0] ctl=0x%08x a0=0x%08x\n",
			mts->tx_prod, mts->tx_cons, ctl0, a0_0);
	}

	while (mts->tx_cons != mts->tx_prod && done < budget) {
		unsigned int entry = mts->tx_cons & (MTS_NUM_TX_DESC - 1);
		u32 ctl_len = le32_to_cpu(READ_ONCE(mts->tx_ring[entry].ctl_len));
		u32 aux0    = le32_to_cpu(READ_ONCE(mts->tx_ring[entry].aux0));

		/* HW completion: OWN=1 AND aux0 not the free-sentinel. */
		if (!(ctl_len & MTS_DESC_OWN) ||
		    (aux0 & MTS_DESC_TX_AUX0_FREE) == MTS_DESC_TX_AUX0_FREE)
			break;

		if (mts->tx_skb[entry]) {
			dma_unmap_single(&mts->pdev->dev, mts->tx_dma[entry],
					 mts->tx_skb[entry]->len,
					 DMA_TO_DEVICE);
			mts->ndev->stats.tx_packets++;
			mts->ndev->stats.tx_bytes += mts->tx_skb[entry]->len;
			dev_consume_skb_any(mts->tx_skb[entry]);
			mts->tx_skb[entry] = NULL;
		}
		/* Restore sentinel for HW: mark slot free. */
		mts->tx_ring[entry].aux0 = cpu_to_le32(MTS_DESC_TX_AUX0_FREE);

		mts->tx_cons++;
		done++;
	}
	spin_unlock_irqrestore(&mts->tx_lock, flags);

	if (done && netif_queue_stopped(mts->ndev))
		netif_wake_queue(mts->ndev);
	return done;
}

/* Drain received frames.  Per hermes mts_rx_process: HW sets OWN=1 with
 * length in bits 0..10; driver reads skb, refills with new skb, clears
 * OWN to hand back. */
static int mts_rx_drain(struct mts *mts, int budget)
{
	int done = 0;

	while (done < budget) {
		unsigned int entry = mts->rx_head & (MTS_NUM_RX_DESC - 1);
		u32 ctl_len = le32_to_cpu(READ_ONCE(mts->rx_ring[entry].ctl_len));
		struct sk_buff *skb;
		unsigned int len;

		/* HW completion: OWN=1 (HW sets when packet received). */
		if (!(ctl_len & MTS_DESC_OWN))
			break;

		len = ctl_len & MTS_DESC_RX_LEN_MASK;
		skb = mts->rx_skb[entry];

		if (skb && len >= ETH_HLEN) {
			dma_unmap_single(&mts->pdev->dev, mts->rx_dma[entry],
					 MTS_RX_BUF_SIZE, DMA_FROM_DEVICE);
			skb_put(skb, len);
			skb->protocol = eth_type_trans(skb, mts->ndev);
			mts->ndev->stats.rx_packets++;
			mts->ndev->stats.rx_bytes += len;
			napi_gro_receive(&mts->napi, skb);
			mts->rx_skb[entry] = NULL;
		} else {
			if (skb) {
				dma_unmap_single(&mts->pdev->dev,
						 mts->rx_dma[entry],
						 MTS_RX_BUF_SIZE,
						 DMA_FROM_DEVICE);
				dev_kfree_skb_any(skb);
				mts->rx_skb[entry] = NULL;
			}
			mts->ndev->stats.rx_errors++;
		}

		/* Refill slot — alloc new SKB, clear OWN to hand to HW. */
		if (mts_rx_alloc(mts, entry)) {
			mts->ndev->stats.rx_dropped++;
			break;
		}

		mts->rx_head++;
		done++;
	}

	/* RX refill kick — bit 2 of BAR+0x38 (RX CTRL register). */
	if (done)
		writel(readl(mts->bar + MTS_RX_CTRL) | MTS_KICK_PKT,
		       mts->bar + MTS_RX_CTRL);

	return done;
}

static int mts_poll(struct napi_struct *napi, int budget)
{
	struct mts *mts = container_of(napi, struct mts, napi);
	int rx_done, tx_done;
	u32 first_ctl;

	tx_done = mts_tx_reap(mts, budget);
	rx_done = mts_rx_drain(mts, budget);

	first_ctl = le32_to_cpu(READ_ONCE(mts->rx_ring[mts->rx_head & (MTS_NUM_RX_DESC - 1)].ctl_len));
	dev_info_ratelimited(&mts->pdev->dev,
			     "v97 poll: tx_done=%d rx_done=%d rx_head=%u rx_ring[head].ctl=0x%08x\n",
			     tx_done, rx_done, mts->rx_head, first_ctl);

	if (rx_done < budget)
		napi_complete_done(napi, rx_done);

	return rx_done;
}

static void mts_get_stats64(struct net_device *ndev,
			    struct rtnl_link_stats64 *stats)
{
	struct mts *mts = netdev_priv(ndev);
	u32 rx_pkts   = readl(mts->bar + 0x118);
	u32 rx_drops  = readl(mts->bar + 0x128);
	u32 rx_errors = readl(mts->bar + 0x12c);

	stats->rx_packets = ndev->stats.rx_packets + rx_pkts;
	stats->tx_packets = ndev->stats.tx_packets;
	stats->rx_bytes   = ndev->stats.rx_bytes;
	stats->tx_bytes   = ndev->stats.tx_bytes;
	stats->rx_errors  = ndev->stats.rx_errors + rx_errors;
	stats->rx_dropped = ndev->stats.rx_dropped + rx_drops;
	stats->tx_dropped = ndev->stats.tx_dropped;
}

static const struct net_device_ops mts_netdev_ops = {
	.ndo_open		= mts_open,
	.ndo_stop		= mts_stop,
	.ndo_start_xmit		= mts_start_xmit,
	.ndo_get_stats64	= mts_get_stats64,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_set_mac_address	= eth_mac_addr,
};

/* end of v93 netdev block */

/*
 * v107: when set to 1 via bootargs (ps4_mts.skip_probe=1), mts_probe returns
 * -ENODEV before touching ANY hardware register.  PCI enumeration still
 * happens, BAR0 is still assigned, and /sys/bus/pci/devices/0000:00:14.1/
 * resource0 remains mmap-able from userspace.  Used to capture a BAR0
 * snapshot of the hardware in Orbis-initialized state for diff analysis
 * against our v97 broken-TX state.
 */
static int skip_probe;
module_param(skip_probe, int, 0444);
MODULE_PARM_DESC(skip_probe,
		 "If 1, skip probe-time hardware init (BAR0 snapshot mode).");

static int mts_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct net_device *ndev;
	struct mts *mts;
	int ret, i;

	if (skip_probe) {
		dev_info(&pdev->dev,
			 "ps4_mts: skip_probe=1, NOT touching hardware (BAR0 snapshot mode)\n");
		return -ENODEV;
	}

	/* v93: alloc_etherdev_mqs(priv_size, txqs, rxqs) — allocates net_device
	 * + private (struct mts) in one go.  Single TX queue, single RX queue.
	 * Auto-freed by devm. */
	ndev = devm_alloc_etherdev_mqs(&pdev->dev, sizeof(*mts), 1, 1);
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, &pdev->dev);
	ndev->netdev_ops = &mts_netdev_ops;
	ndev->watchdog_timeo = 5 * HZ;
	strscpy(ndev->name, "mts%d", IFNAMSIZ);
	eth_hw_addr_random(ndev);

	mts = netdev_priv(ndev);
	mts->ndev = ndev;
	mts->pdev = pdev;
	spin_lock_init(&mts->tx_lock);

	netif_napi_add(ndev, &mts->napi, mts_poll);

	ret = pcim_enable_device(pdev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "pcim_enable_device\n");

	ret = pcim_iomap_regions(pdev, BIT(0), DRV_NAME);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "pcim_iomap_regions BAR0\n");
	mts->bar = pcim_iomap_table(pdev)[0];

	pci_set_master(pdev);
	/* drvdata set to ndev at end of probe (after register_netdev). */

	dev_info(&pdev->dev, "Baikal MTS: BAR0=%pR, mapped at %p\n",
		 &pdev->resource[0], mts->bar);

	/*
	 * v84: ensure 32-bit DMA mask before allocating descriptor rings.
	 * BAR+0x3c..0x48 have hi/lo halves so 64-bit is technically supported,
	 * but 32-bit keeps us simple and inside the typical PCI DMA range.
	 */
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "dma_set_mask_and_coherent(32)\n");

	/*
	 * Allocate minimal DMA-coherent TX/RX descriptor rings.  v84's hypothesis:
	 * starting the RX engine is what lets the MAC monitor the PHY link signal
	 * - even an empty ring should be enough for the link-status bit at
	 * BAR+0x04 bit 0 to latch.
	 */
	mts->tx_ring_virt = dmam_alloc_coherent(&pdev->dev, MTS_RING_BYTES,
						 &mts->tx_ring_dma, GFP_KERNEL);
	if (!mts->tx_ring_virt)
		return dev_err_probe(&pdev->dev, -ENOMEM, "TX ring alloc\n");
	mts->rx_ring_virt = dmam_alloc_coherent(&pdev->dev, MTS_RING_BYTES,
						 &mts->rx_ring_dma, GFP_KERNEL);
	if (!mts->rx_ring_virt)
		return dev_err_probe(&pdev->dev, -ENOMEM, "RX ring alloc\n");
	mts->tx_ring = (struct mts_desc *)mts->tx_ring_virt;
	mts->rx_ring = (struct mts_desc *)mts->rx_ring_virt;
	dev_info(&pdev->dev,
		 "DMA rings: TX=%pad RX=%pad (each %u bytes, zeroed)\n",
		 &mts->tx_ring_dma, &mts->rx_ring_dma, MTS_RING_BYTES);

	/*
	 * Register the stub ISR BEFORE mts_mac_init enables the BAR+0x204 IRQ
	 * block.  This prevents the IRQ-vector flood that crashed v83.
	 *
	 * pdev->irq is 0 by default on PS4 Baikal because the bpcie infrastructure
	 * manages MSI through a custom IRQ domain.  We must call
	 * pci_alloc_irq_vectors(MSI) to get an actual Linux IRQ number bound to
	 * the device.  pci_irq_vector(pdev, 0) then returns the allocated vector.
	 */
	atomic_set(&mts->isr_link_change_count, 0);
	atomic_set(&mts->isr_total_count, 0);
	for (i = 0; i < MTS_ISR_HIST_SLOTS; i++) {
		mts->isr_hist_pattern[i] = 0;
		atomic_set(&mts->isr_hist_count[i], 0);
	}
	mts->isr_last_linkreg = 0;

	ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI | PCI_IRQ_INTX);
	if (ret < 0) {
		dev_err(&pdev->dev, "pci_alloc_irq_vectors failed: %d\n", ret);
		return ret;
	}
	mts->irq = pci_irq_vector(pdev, 0);
	if (mts->irq < 0) {
		dev_err(&pdev->dev, "pci_irq_vector returned %d\n", mts->irq);
		pci_free_irq_vectors(pdev);
		return mts->irq;
	}
	ret = request_irq(mts->irq, mts_intr, IRQF_SHARED, DRV_NAME, mts);
	if (ret) {
		dev_err(&pdev->dev, "request_irq(%d) failed: %d\n", mts->irq, ret);
		pci_free_irq_vectors(pdev);
		return ret;
	}
	mts->irq_registered = true;
	dev_info(&pdev->dev, "registered ISR on IRQ %d (%s)\n", mts->irq,
		 pdev->msi_enabled ? "MSI" : "INTx");

	/* v105: full MAC + PHY bring-up moved to ndo_open (mts_open).
	 * Probe now only: enable PCI, map BAR, alloc DMA rings, register
	 * IRQ, set up timers + kthread, register netdev.  The MAC stays
	 * uninitialized until userspace does `ip link set up` which calls
	 * ndo_open and runs mts_parent_prelude + mts_mac_init + mts_phy_init.
	 * Rationale: MAC's one-shot link-status latch in BAR+0x04 bit 0
	 * evaluates during the fresh mac_init bring-up.  v97+ ran mac_init
	 * during probe (latch sampled before PHY linked), but v97+ added
	 * netdev pre-fill that broke v91's working timing.  Moving init
	 * to ndo_open matches Orbis mts_ifup structure.
	 */
	timer_setup(&mts->link_poll, mts_link_poll, 0);
	mts->last_link = ~0U;
	mod_timer(&mts->link_poll, jiffies + HZ);

	/* v85 debug telemetry timer - dumps histogram + state every 5s. */
	timer_setup(&mts->dbg_timer, mts_dbg_timer_fn, 0);
	mod_timer(&mts->dbg_timer,
		  jiffies + msecs_to_jiffies(MTS_DBG_TIMER_PERIOD_MS));

	/*
	 * Spawn the SMI heartbeat thread.  Must outlive the link-poll timer so
	 * SMI stays exercised even when no link transitions occur.  See
	 * mts_phy_ctrl_fn comment for the kthread-heartbeat rationale.
	 */
	mts->phy_addr = 0;
	mts->phy_ctrl_thread = kthread_run(mts_phy_ctrl_fn, mts,
					   "ps4_mts_phy_ctrl");
	if (IS_ERR(mts->phy_ctrl_thread)) {
		dev_warn(&pdev->dev, "phy_ctrl kthread spawn failed (%ld) - SMI will die after ~1min\n",
			 PTR_ERR(mts->phy_ctrl_thread));
		mts->phy_ctrl_thread = NULL;
	}

	pci_set_drvdata(pdev, ndev);

	/* v93: register netdev LAST in probe.  Until this call userspace
	 * cannot see mts0; if any earlier step fails, no half-initialized
	 * interface ever appears.  netif_carrier_off until ndo_open. */
	netif_carrier_off(ndev);
	ret = register_netdev(ndev);
	if (ret) {
		dev_err(&pdev->dev, "register_netdev failed: %d\n", ret);
		return ret;
	}
	mts->netdev_registered = true;
	dev_info(&pdev->dev, "v93: netdev %s registered (MAC %pM)\n",
		 ndev->name, ndev->dev_addr);

	return 0;
}

static void mts_remove(struct pci_dev *pdev)
{
	struct net_device *ndev = pci_get_drvdata(pdev);
	struct mts *mts = netdev_priv(ndev);

	/*
	 * v113: hotswap-safe remove.  Agents (hermes+kimi+deepseek+glm,
	 * 2026-05-14) flagged that if any DMA engine or kthread fires
	 * after rmmod has freed module text/rings, the southbridge can
	 * wedge into power-cycle territory.  Order matters:
	 *   1) unregister_netdev (which does netif_stop_queue + napi_disable)
	 *   2) wake + stop kthreads (wake first so they can observe
	 *      kthread_should_stop() and exit interruptible sleep)
	 *   3) delete timers (synchronous — won't fire after this)
	 *   4) stop RX/TX engines (so no new DMA completions)
	 *   5) disable IRQ block (so no new MSIs)
	 *   6) W1C any pending IRQ status (so no stale IRQ on next insmod)
	 *   7) free_irq (must precede pci_free_irq_vectors)
	 *   8) pci_free_irq_vectors
	 */
	if (mts->netdev_registered)
		unregister_netdev(ndev);
	netif_napi_del(&mts->napi);

	if (mts->phy_ctrl_thread) {
		wake_up_process(mts->phy_ctrl_thread);
		kthread_stop(mts->phy_ctrl_thread);
	}
	timer_delete_sync(&mts->dbg_timer);
	timer_delete_sync(&mts->link_poll);

	/* Stop RX/TX engines before disabling the IRQ block. */
	writel(readl(mts->bar + MTS_RX_KICK) & ~MTS_ENGINE_START,
	       mts->bar + MTS_RX_KICK);
	writel(readl(mts->bar + MTS_TX_KICK) & ~MTS_ENGINE_START,
	       mts->bar + MTS_TX_KICK);

	writel(0, mts->bar + MTS_IRQ_ENABLE_FULL);
	writel(0, mts->bar + MTS_IRQ_MASK);
	/* v113: W1C any pending IRQ status — otherwise a stale bit
	 * could trigger the very first IRQ on the next insmod before
	 * our handlers are wired up. */
	writel(readl(mts->bar + MTS_IRQ_STATUS), mts->bar + MTS_IRQ_STATUS);
	(void)readl(mts->bar + MTS_IRQ_STATUS);

	if (mts->irq_registered) {
		free_irq(mts->irq, mts);
		pci_free_irq_vectors(pdev);
	}
	/* DMA rings auto-freed by dmam; netdev auto-freed by devm. */
}

static const struct pci_device_id mts_pci_id_table[] = {
	{ PCI_DEVICE(PCI_VENDOR_ID_SONY, PCI_DEVICE_ID_SONY_BAIKAL_GBE) },
	{ 0 }
};
MODULE_DEVICE_TABLE(pci, mts_pci_id_table);

static struct pci_driver mts_pci_driver = {
	.name     = DRV_NAME,
	.id_table = mts_pci_id_table,
	.probe    = mts_probe,
	.remove   = mts_remove,
};

module_pci_driver(mts_pci_driver);

MODULE_AUTHOR("PS4 Linux Baikal Port");
MODULE_DESCRIPTION("Sony PS4 Baikal Gigabit Ethernet (MTS)");
MODULE_LICENSE("GPL v2");
