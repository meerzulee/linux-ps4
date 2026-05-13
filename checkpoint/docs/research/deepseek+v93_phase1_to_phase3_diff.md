# deepseek+v93_phase1_to_phase3_diff.md — 2026-05-13

## Current state audit (ps4_mts.c, 1346 lines)

The driver has **link UP confirmed** (or imminent) with v91's status-unit
OP_ON + v92's TXEN_DIG clear.  Adding netdev must preserve everything that
got us here while adding the net device framework.

## Question-by-question answers

### (1) ISR: histogram → NAPI conversion

**Current:** 16-slot lockless histogram in `mts_intr_stub` (lines 818-873).
Diagnostic-only — never processes RX/TX, only records IRQ patterns.

**Needed:** NAPI-scheduled ISR.  On RX-ready IRQ (bit 12 = 0x1000), schedule
NAPI → NAPI poll walks RX descriptors → hands skbs to netif_receive_skb().
On TX-complete (bit 7 = 0x80), just W1C-ack; NAPI poll cleans up TX ring.

**Plan:** REMOVE histogram entirely (lines 818-873: `mts_intr_stub`).
REPLACE with:

```c
static irqreturn_t mts_intr(int irq, void *dev_id)
{
    struct net_device *dev = dev_id;
    struct mts *mts = netdev_priv(dev);
    u32 status = readl(mts->bar + MTS_IRQ_STATUS);

    if (!status)
        return IRQ_NONE;

    writel(status, mts->bar + MTS_IRQ_STATUS);
    (void)readl(mts->bar + MTS_IRQ_STATUS);

    if (status & (0x1000 | 0x40 | 0x80)) {  // RX ready, RX done, TX done
        if (napi_schedule_prep(&mts->napi)) {
            __napi_schedule(&mts->napi);
        }
    }

    if (status & MTS_IRQ_LINK_CHANGE) {
        /* Phylib handles link state; we just log for now */
    }

    return IRQ_HANDLED;
}
```

REMOVE: `isr_hist_pattern[]`, `isr_hist_count[]`, `isr_total_count`,
`isr_link_change_count`, `isr_last_linkreg` from struct mts (lines 160-164).

ADD to struct mts: `struct napi_struct napi;`

### (2) phy_ctrl kthread: keep for heartbeat, phylib for link

**Current:** `mts_phy_ctrl_fn` (lines 961-1081) does three things:
a. SMI heartbeat (reads BAR+0x04 + BMSR every 3s → keeps MDC alive)
b. Link monitoring (BAR+0x04 + BMSR logging)
c. AN restart on link-down (event 0x1 handler)

**Needed for netdev:**
- SMI heartbeat: MUST KEEP. phylib doesn't provide periodic MDIO bus touch.
  Without it, the transaction-gated MDC clock domain dies after ~1min.
- Link monitoring: REPLACE with phylib's `adjust_link` callback.
- AN restart: REPLACE with phylib's phy_start/phy_stop state machine.

**Plan:** KEEP the kthread but SIMPLIFY it to heartbeat-only (no PHY logic):

```c
static int mts_heartbeat_fn(void *data)
{
    struct mts *mts = data;
    while (!kthread_should_stop()) {
        u16 dummy;
        mts_smi_c22_read(mts, 0x01, &dummy);  // touch SMI
        msleep_interruptible(MTS_PHY_CTRL_PERIOD_MS);
    }
    return 0;
}
```

REGISTER an mdio_bus in probe that uses our `mts_smi_c22_read/write` as
read/write callbacks.  Phylib will bind the MT7531 PHY driver and handle
link state machine automatically.

REMOVE from struct mts: `last_phy_link_up`, `initial_an_done`,
`link_down_iterations` (lines 141-143).  Phylib tracks these.

REMOVE: `mts_phy_an_restart()` (lines 926-941) — phylib handles this.

REMOVE: `mts_phy_init()` (lines 752-771) — phylib's config_init replaces it.

KEEP: the kthread itself (just simplified).  KEEP `MTS_PHY_CTRL_PERIOD_MS`.

### (3) dbg_timer: keep as debug, gate behind compile flag

**Current:** `mts_dbg_timer_fn` (lines 880-915) dumps histogram + BAR state
every 5s.  ~40 lines of log per dump.

**Plan:** KEEP the function but gate it behind `#ifdef DEBUG`.  Without
the histogram, it becomes a simple linkreg-change log:

```c
#ifdef DEBUG
static void mts_dbg_timer_fn(struct timer_list *t) { ... }
#endif
```

Or: convert to periodic ethtool statistics update instead of printk.

REMOVE from struct mts: histogram fields (already removed in step 1).
KEEP: `dbg_timer` and `MTS_DBG_TIMER_PERIOD_MS` (gated).

### (4) Engine start: MOVE to ndo_open

**Current:** engines started in probe (lines 1182-1200):
```
writel(tx_dma_lo, BAR+0x3c);  // TX desc
writel(rx_dma_lo, BAR+0x40);  // RX desc
writel(rx_dma_hi, BAR+0x44);  // TX desc hi (BUG: 0x44 is RX desc hi)
writel(tx_dma_hi, BAR+0x48);  // RX desc hi (BUG: 0x48 is TX desc hi)
BAR+0x34 |= 1;  // RX engine start
BAR+0x38 |= 1;  // TX engine start  (NOTE: writes 0x01, but Orbis writes 0x08 too)
```

**CRITICAL BUG found:** Lines 1182-1185 have swapped HI/LO mappings:
- Line 1182: `writel(tx_ring_dma, BAR + MTS_TX_DESC_LO)` — correct (TX-lo to 0x3c)
- Line 1183: `writel(upper_32_bits(tx_ring_dma), BAR + MTS_TX_DESC_HI)` — writes TX-hi to BAR+0x44. OK.
- Line 1184: `writel(rx_ring_dma, BAR + MTS_RX_DESC_LO)` — writes RX-lo to BAR+0x40. OK.
- Line 1185: `writel(upper_32_bits(rx_ring_dma), BAR + MTS_RX_DESC_HI)` — writes RX-hi to BAR+0x48. OK.

Actually looking at the defines: MTS_TX_DESC_LO=0x3c, MTS_TX_DESC_HI=0x44, MTS_RX_DESC_LO=0x40, MTS_RX_DESC_HI=0x48. This matches Orbis. The code is correct.

But note: BAR+0x38 is TX_KICK. We write `readl(BAR+0x38) | 1`. But Orbis also writes `BAR+0x38 |= 4` (bit 2) on TX error recovery in mts_intr. And Orbis writes `BAR+0x38 = 1` initially in mts_init_rings_kick. Our write of just bit 0 should be sufficient.

**Plan:** MOVE descriptor DMA address writes + engine starts from probe to
`ndo_open()`.  In probe, only ALLOCATE rings.  In ndo_open, INITIALIZE
descriptors, WRITE DMA addresses, START engines.

This is the standard Linux netdev pattern: probe allocates resources,
ndo_open starts hardware, ndo_stop stops hardware.

Lines to MOVE from probe to ndo_open:
- 1182-1185: descriptor DMA address writes
- 1193-1200: engine starts (BAR+0x34 |= 1, BAR+0x38 |= 1)
- 1214-1222: status unit OP_ON (v91a)

KEEP in probe:
- 1124-1133: DMA ring allocation (dmam_alloc_coherent)
- 1174-1175: parent_prelude + mac_init (hardware init)
- 1224-1250: MMD diagnostic reads (one-time at probe)

### (5) Ring sizing and OWN bits

**Current:** 4KB per ring, zeroed.  No descriptor initialization at all.
`dmam_alloc_coherent` gives zero-filled memory, so all descriptors have
`OWN = 0` (owned by driver = idle).  This is CORRECT for TX (driver owns
all TX slots initially) but WRONG for RX (HW needs OWN=1 to write packets).

**Plan:** Keep 4KB (= 256 × 16 bytes).  Corrent size per Orbis (256 entries).
NEED to pre-fill RX descriptors:

In ndo_open, after writing DMA addresses:
```c
for (i = 0; i < MTS_NUM_DESC; i++) {
    struct mts_desc *rxd = &mts->rx_ring[i];
    dma_addr_t buf_dma;
    struct sk_buff *skb = netdev_alloc_skb(dev, MTS_RX_BUF_SIZE);
    if (!skb) break;
    buf_dma = dma_map_single(dev, skb->data, MTS_RX_BUF_SIZE, DMA_FROM_DEVICE);
    rxd->control = cpu_to_le32(0x80000000 | MTS_RX_BUF_SIZE);  // OWN=1 + length
    rxd->addr_lo = cpu_to_le32(lower_32_bits(buf_dma));
    rxd->addr_hi = cpu_to_le32(upper_32_bits(buf_dma));
    rxd->vlan_tag = 0;
    rxd->reserved = 0;
    mts->rx_skb[i] = skb;
    mts->rx_dma[i] = buf_dma;
}
/* Last entry: set ring-wrap bit */
mts->rx_ring[MTS_NUM_DESC - 1].control |= cpu_to_le32(0x40000000);
```

ADD to struct mts:
```c
#define MTS_NUM_DESC    256
#define MTS_RX_BUF_SIZE 2048   /* max frame + alignment */

struct mts_desc {
    __le32 control;     /* bit31=OWN, bit30=wrap, bits0-10=length */
    __le32 addr_lo;     /* buffer DMA address low */
    __le16 vlan_tag;    /* VLAN tag / checksum start */
    __le16 reserved;
} ____cacheline_aligned;

struct mts_desc *tx_ring __aligned(16);
struct mts_desc *rx_ring __aligned(16);
struct sk_buff *rx_skb[MTS_NUM_DESC];
dma_addr_t rx_dma[MTS_NUM_DESC];
struct sk_buff *tx_skb[MTS_NUM_DESC];
u16 tx_prod, tx_cons;
u16 rx_put;
```

REMOVE: `tx_ring_virt`, `rx_ring_virt` (void*), replace with typed pointers.

### (6) IRQ mask: keep current 0x7bbffe

**Current:** `MTS_IRQ_BIT18 = 0x00040000`, `MTS_IRQ_MASK_FULL_VAL = 0x007bbffe`
(bit 18 gated due to v85 5670Hz flood).

**Bit map of 0x007bbffe:**
- Bit 2 (0x04): link change — ENABLED (needed for phylib)
- Bit 6 (0x40): RX completion — ENABLED
- Bit 7 (0x80): TX completion — ENABLED
- Bit 12 (0x1000): RX packet ready — ENABLED
- Bit 14 (0x4000): TCP_CKS error — ENABLED (logged, not acted on)
- Bit 15 (0x8000): IP_CKS error — ENABLED (logged)
- Bit 16 (0x10000): — ENABLED
- Bit 17 (0x20000): RX_AXI_ERR — ENABLED (logged)
- Bit 18 (0x40000): secondary state — GATED (was 5670Hz flood)
- Bit 19 (0x80000): LSO_PRO_ERR — ENABLED
- Bit 20 (0x100000): — ENABLED
- Bit 21 (0x200000): LSO_FIFO_EMPTY — ENABLED
- Bit 22 (0x400000): — ENABLED
- Bit 23 (0x800000): Master MAC Error — ENABLED

**Plan:** KEEP current mask `0x007bbffe`.  The RX/TX completion and packet-
ready bits (6,7,12) are ALREADY ENABLED in this mask.  Bit 18 stays gated
until we understand the flood (possibly the "secondary MAC state" IRQ that
needs BAR+0x204 write to quiet, as Orbis mts_intr handles).

If bit 18 flood re-occurs after engine start: add the Orbis bit-18 handler
(disable BAR+0x204, mask back to saved value).  For now, gating it is safe.

## Concrete diff plan

### Lines to REMOVE (diagnostic/phase-1 scaffolding)

| Lines | What | Why |
|-------|------|-----|
| 136-142 | `last_phy_link_up`, `initial_an_done`, `link_down_iterations` | phylib replaces link tracking |
| 145-153 | ISR histogram fields + `isr_link_change_count` + `irq`/`irq_registered` | NAPI ISR replaces histogram |
| 160-164 | `isr_hist_pattern[]`, `isr_hist_count[]`, `isr_total_count`, `isr_last_linkreg`, `dbg_timer` | Histogram → ethtool stats (or removed) |
| 752-771 | `mts_phy_init()` | phylib config_init replaces |
| 773-805 | `mts_link_poll()` timer fn | phylib adjust_link replaces |
| 818-873 | `mts_intr_stub()` + histogram | NAPI ISR replaces |
| 880-915 | `mts_dbg_timer_fn()` | Gate behind `#ifdef DEBUG` or remove |
| 926-941 | `mts_phy_an_restart()` | phylib handles AN |

### Lines to KEEP (working hardware init)

| Lines | What | Status |
|-------|------|--------|
| 172-212 | SMI C22 read/write | KEEP AS-IS — proven correct |
| 225-300 | SMI C45 read/write | KEEP AS-IS — proven correct |
| 322-357 | `mts_phy_pll_enable()` | KEEP — called from mac_init |
| 371-400 | `mts_parent_prelude()` | KEEP — switch reset + clock glue |
| 412-741 | `mts_mac_init()` | KEEP — full MAC + PHY init sequence |
| 1124-1133 | DMA ring allocation | KEEP — but types change |
| 1136-1172 | IRQ vector alloc + request_irq | KEEP — but ISR function changes |
| 1214-1222 | v91a status unit OP_ON | KEEP — but MOVE to ndo_open |
| 1252-1277 | SMI sweep + PHY ID | KEEP — one-time diagnostic at probe |
| 1292-1299 | phy_ctrl kthread spawn | KEEP — but simplify to heartbeat |

### Lines to MODIFY (change behavior)

| Lines | Change |
|-------|--------|
| 132-165 | `struct mts`: ADD napi, desc rings typed, skb arrays, mdio bus, phydev. REMOVE histogram, link tracking, dbg_timer |
| 961-1081 | `mts_phy_ctrl_fn`: SIMPLIFY to heartbeat-only SMI touch. REMOVE all link logic, AN restart, BMSR double-read |
| 1083-1302 | `mts_probe`: ADD netdev alloc/register, mdio_bus register. MOVE engine start + status unit to ndo_open. KEEP all hardware init |
| 1304-1327 | `mts_remove`: ADD netdev unregister, mdio_bus unregister, napi_disable |

### Lines to ADD (new functions)

| Function | Purpose |
|----------|---------|
| `mts_open()` | ndo_open: init descriptors, write DMA addrs, start engines, start phy, napi_enable |
| `mts_stop()` | ndo_stop: stop engines, stop phy, napi_disable, free RX skbs, free TX skbs |
| `mts_start_xmit()` | ndo_start_xmit: fill TX desc, kick TX engine, return NETDEV_TX_OK/BUSY |
| `mts_poll()` | NAPI poll: walk RX descriptors, build skbs, netif_receive_skb, refill RX, walk TX cleanup |
| `mts_adjust_link()` | phylib callback: read link state, update netdev carrier |
| `mts_mdio_read/write()` | MDIO bus accessors wrapping our SMI functions |
| `mts_heartbeat_fn()` | Simplified kthread: just SMI touch every 3s |

### Probe flow (after modifications)

```
mts_probe:
  1. devm_kzalloc (mts + netdev_priv)    ← ADD net_device alloc
  2. pcim_enable_device, iomap, set_master
  3. dma_set_mask_and_coherent(32)
  4. ALLOCATE DMA rings (dmam_alloc_coherent) ← KEEP, types changed
  5. pci_alloc_irq_vectors + request_irq(mts_intr, ...name="ps4_mts")
  6. mts_parent_prelude()                  ← KEEP
  7. mts_mac_init()                        ← KEEP
  8. SMI sweep + PHY ID log               ← KEEP
  9. REGISTER mdio_bus (mdiobus_register) ← ADD
  10. CONNECT phy (phy_connect)            ← ADD
  11. netdev_register (register_netdev)    ← ADD
  12. SPAWN heartbeat kthread              ← KEEP (simplified)
  13. return 0

mts_open (ndo_open):
  1. INIT RX descriptors (pre-fill OWN=1 + skb + DMA map)
  2. WRITE DMA addresses (BAR+0x3c/0x40/0x44/0x48)
  3. START RX engine (BAR+0x34 |= 1)
  4. START TX engine (BAR+0x38 |= 1)
  5. STATUS unit OP_ON (BAR+0xe80 = 1,2,8)
  6. phy_start(phydev)
  7. napi_enable(&napi)
  8. netif_start_queue(dev)
```

### Risk minimization

1. **Link-up is sacred.** All hardware init that produced working link
   (parent_prelude + mac_init + PHY PLL + v87 tail + v88 DSP + v89
   TX delay + v91 status unit) stays EXACTLY as-is in probe, line for line.

2. **Engine start moves to open.** This is standard — engines don't need to
   run before the interface is brought up.  ndo_stop can stop them.

3. **ISR stays simple.** The new NAPI ISR is actually SIMPLER than the
   histogram ISR.  Less code → fewer bugs.

4. **SMI heartbeat stays.** The simplified kthread is ~10 lines and can't
   break anything.

5. **phylib is additive.** We register an mdio_bus and let phylib manage
   the PHY.  If phylib fails to bind, the driver still works (just no
   link state machine — same as phase 1).  Non-fatal.

6. **Netdev registration comes LAST in probe.** If anything before it fails,
   we never register the interface.  No half-initialized netdev visible
   to userspace.

--- deepseek-v41, 2026-05-13
