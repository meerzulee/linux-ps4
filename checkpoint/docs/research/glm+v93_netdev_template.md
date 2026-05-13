# v93: Netdev Template Research for ps4_mts Phase 3

**Date:** 2026-05-13
**Goal:** Find the cleanest mainline template for wrapping ps4_mts with
alloc_etherdev / register_netdev / NAPI / TX+RX rings / MSI single-vector.

---

## 1. Best Template: Cadence macb (macb_main.c)

**Why macb over mvneta or igb:**

| Feature | macb (5677 LOC) | mvneta (5975 LOC) | igb (10263 LOC) |
|---|---|---|---|
| OWN-bit descriptors | ✅ TX_USED/RX_USED | ❌ custom queue system | ✅ but 8-ring multi-queue |
| Single TX+RX ring | ✅ (also multi-queue, but single-queue path is clean) | ❌ multi-queue only | ❌ 8 queues hardcoded |
| NAPI per-queue | ✅ napi_rx + napi_tx | ✅ but complex | ❌ NAPI per vector |
| 16-byte desc format | ✅ struct macb_dma_desc (4×32-bit) | ❌ different layout | ✅ but legacy size |
| DMA coherent rings | ✅ dma_alloc_coherent | ✅ | ✅ but complex |
| MSI single-vector path | N/A (platform) but ISR structure is simple | ✅ | ❌ multi-vector |
| Netdev ops structure | ✅ clean, 11 ops | ✅ but 20+ ops | ❌ 30+ ops |
| Platform vs PCI | Platform | Platform | **PCI** ← only igb is PCI |

**The winner is macb** because:
- 16-byte `macb_dma_desc` (addr + ctrl fields) is almost identical to MTS's
  16-byte descriptor format (addr + control)
- OWN-bit semantics (TX_USED/RX_USED) match MTS (bit 31 = OWN)
- Single-queue path is simple and well-factored
- ISR → NAPI → poll → rx/tx_complete is textbook clean
- `gem_rx_refill()` pattern is exactly what MTS needs

**The one thing to copy from igb:** PCI device setup (pci_enable_device,
pci_request_regions, pci_set_dma_mask, pci_iomap). But macb is platform,
so we adapt the PCI bits from our existing probe.

---

## 2. Skeleton Structure for ps4_mts

```c
/* ps4_mts.h — private data */
struct mts_desc {
    __le32 addr;     /* buffer address (low 32 for now) */
    __le32 ctrl;     /* OWN bit 31, length bits 15:0, etc */
    __le32 addr_hi;  /* buffer address high 32 (for 64-bit) */
    __le32 reserved;
};

struct mts_ring {
    struct mts_desc  *desc;          /* DMA coherent ring */
    dma_addr_t        desc_dma;     /* bus address of ring */
    struct sk_buff  **skb;           /* skb array for TX/RX */
    unsigned int      head;          /* next to fill (TX: fill, RX: refill) */
    unsigned int      tail;          /* next to complete */
    unsigned int      count;         /* ring size (power of 2) */
};

struct mts_stats {
    u64 rx_packets, rx_bytes;
    u64 tx_packets, tx_bytes;
    u64 rx_dropped, rx_errors;
    u64 tx_errors, tx_dropped;
};

struct mts {
    struct pci_dev       *pdev;
    struct net_device    *dev;
    void __iomem         *bar;       /* MMIO base */

    struct mts_ring       tx_ring;
    struct mts_ring       rx_ring;

    struct napi_struct    napi;      /* single NAPI for RX+TX */
    struct msi_map        msi;       /* single MSI vector */

    u32                   irq_status_cached;
    u32                   link_state;  /* BAR+0x04 shadow */
    struct timer_list     link_poll;   /* until we get link-change IRQ */

    spinlock_t            tx_lock;     /* TX ring protection */
    struct mts_stats      stats;

    /* PHY state */
    u16                   phy_id1, phy_id2;
};
```

```c
/* ps4_mts.c — function skeleton */

/* ---- PCI ---- */
static int  mts_pci_probe(struct pci_dev *, const struct pci_device_id *);
static void mts_pci_remove(struct pci_dev *);

/* ---- Netdev ops ---- */
static int  mts_ndo_open(struct net_device *);
static int  mts_ndo_stop(struct net_device *);
static netdev_tx_t mts_ndo_start_xmit(struct sk_buff *, struct net_device *);
static void mts_ndo_set_rx_mode(struct net_device *);
static int  mts_ndo_set_mac_addr(struct net_device *, void *);
static void mts_ndo_get_stats64(struct net_device *, struct rtnl_link_stats64 *);

static const struct net_device_ops mts_netdev_ops = {
    .ndo_open           = mts_ndo_open,
    .ndo_stop           = mts_ndo_stop,
    .ndo_start_xmit     = mts_ndo_start_xmit,
    .ndo_set_rx_mode    = mts_ndo_set_rx_mode,
    .ndo_set_mac_address= eth_mac_addr,      /* or mts_ndo_set_mac_addr */
    .ndo_validate_addr  = eth_validate_addr,
    .ndo_get_stats64    = mts_ndo_get_stats64,
};

/* ---- NAPI ---- */
static int  mts_napi_poll(struct napi_struct *, int budget);

/* ---- IRQ ---- */
static irqreturn_t mts_isr(int irq, void *dev_id);

/* ---- TX/RX ---- */
static void mts_tx_complete(struct mts *mts);
static int  mts_rx_poll(struct mts *mts, int budget);
static void mts_rx_refill(struct mts *mts);

/* ---- Ring management ---- */
static int  mts_alloc_rings(struct mts *mts);
static void mts_free_rings(struct mts *mts);
static void mts_init_rings(struct mts *mts);

/* ---- Link ---- */
static void mts_link_poll(struct timer_list *t);
static void mts_check_link(struct mts *mts);
```

---

## 3. alloc_etherdev / register_netdev Sequence

From macb_probe() (adapted for PCI):

```c
static int mts_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct net_device *dev;
    struct mts *mts;
    int err;

    err = pci_enable_device(pdev);
    if (err) return err;

    err = pci_request_regions(pdev, DRV_NAME);
    if (err) goto err_disable;

    err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (err) {
        err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
        if (err) goto err_release;
    }

    dev = alloc_etherdev(sizeof(*mts));
    if (!dev) { err = -ENOMEM; goto err_release; }

    SET_NETDEV_DEV(dev, &pdev->dev);
    pci_set_drvdata(pdev, dev);
    mts = netdev_priv(dev);
    mts->pdev = pdev;
    mts->dev = dev;

    mts->bar = pci_iomap(pdev, 0, 0);
    if (!mts->bar) { err = -EIO; goto err_free_netdev; }

    /* MAC init (existing phase 1/2 code) */
    mts_mac_init(mts);
    mts_phy_init(mts);

    /* Get MAC address from BAR (Orbis reads from BAR+0x14/0x18) */
    eth_hw_addr_set(dev, mts->mac_addr);  /* or eth_hw_addr_random(dev) */

    /* Setup netdev */
    dev->netdev_ops = &mts_netdev_ops;
    dev->flags |= IFF_MULTICAST;
    netif_napi_add(dev, &mts->napi, mts_napi_poll);

    err = register_netdev(dev);
    if (err) goto err_iounmap;

    return 0;

err_iounmap:
    pci_iounmap(pdev, mts->bar);
err_free_netdev:
    free_netdev(dev);
err_release:
    pci_release_regions(pdev);
err_disable:
    pci_disable_device(pdev);
    return err;
}

static void mts_pci_remove(struct pci_dev *pdev)
{
    struct net_device *dev = pci_get_drvdata(pdev);
    struct mts *mts = netdev_priv(dev);

    unregister_netdev(dev);
    netif_napi_del(&mts->napi);
    pci_iounmap(pdev, mts->bar);
    free_netdev(dev);
    pci_release_regions(pdev);
    pci_disable_device(pdev);
}
```

---

## 4. NAPI ↔ ISR Wiring

Single MSI vector, single NAPI for both RX and TX (like macb's single-queue path):

```c
/* ISR — minimal, schedule NAPI and acknowledge */
static irqreturn_t mts_isr(int irq, void *dev_id)
{
    struct net_device *dev = dev_id;
    struct mts *mts = netdev_priv(dev);
    u32 status;

    status = readl(mts->bar + MTS_IRQ_STATUS);
    if (!status)
        return IRQ_NONE;

    /* Acknowledge all pending interrupts */
    writel(status, mts->bar + MTS_IRQ_STATUS);
    /* Readback flush */
    (void)readl(mts->bar + MTS_IRQ_STATUS);

    mts->irq_status_cached |= status;

    if (status & (MTS_IRQ_RX | MTS_IRQ_TX_DONE | MTS_IRQ_LINK)) {
        if (napi_schedule_prep(&mts->napi)) {
            /* Disable interrupts, let NAPI poll */
            writel(0, mts->bar + MTS_IRQ_MASK);
            __napi_schedule(&mts->napi);
        }
    }

    return IRQ_HANDLED;
}

/* NAPI poll — process RX and TX */
static int mts_napi_poll(struct napi_struct *napi, int budget)
{
    struct mts *mts = container_of(napi, struct mts, napi);
    u32 status = mts->irq_status_cached;
    int work_done = 0;

    /* Process TX completions first (lightweight) */
    if (status & MTS_IRQ_TX_DONE)
        mts_tx_complete(mts);

    /* Process RX packets up to budget */
    if (status & MTS_IRQ_RX)
        work_done = mts_rx_poll(mts, budget);

    /* Check link status */
    if (status & MTS_IRQ_LINK)
        mts_check_link(mts);

    mts->irq_status_cached = 0;

    if (work_done < budget && napi_complete_done(napi, work_done)) {
        /* Re-enable interrupts */
        writel(MTS_IRQ_ENABLE_FULL_VAL, mts->bar + MTS_IRQ_ENABLE_FULL);
        writel(MTS_IRQ_MASK_FULL_VAL, mts->bar + MTS_IRQ_MASK);
    }

    return work_done;
}
```

Key IQR bit constants from Orbis RE (BAR+0x050 IRQ_STATUS):
```
MTS_IRQ_LINK    = BIT(2)    /* link status change */
MTS_IRQ_RX      = BIT(6)    /* RX done */
MTS_IRQ_TX_DONE = BIT(31)   /* TX complete (bit 31 per ISR code) */
MTS_IRQ_ENABLE_FULL_VAL = 0x10001388  /* from mts_intr */
MTS_IRQ_MASK_FULL_VAL   = 0x007bfffe  /* from gbe:ctrl init */
```

---

## 5. SKB Lifecycle in TX/RX Path

### TX (start_xmit → tx_complete)

```
ndo_start_xmit()
  └─> mts_ndo_start_xmit(skb, dev)
       │  spin_lock(&mts->tx_lock)
       │  // Check for free descriptors:
       │  if (no free desc) {
       │      netif_stop_queue(dev);
       │      spin_unlock(); return NETDEV_TX_BUSY;
       │  }
       │  // Map skb data for DMA:
       │  mapping = dma_map_single(&pdev->dev, skb->data, skb->len, DMA_TO_DEVICE);
       │  // Fill descriptor:
       │  desc->addr = cpu_to_le32(mapping);
       │  desc->ctrl = cpu_to_le32(skb->len | MTS_DESC_OWN | MTS_DESC_FS | MTS_DESC_LS);
       │  mts->tx_ring.skb[head] = skb;       // save for cleanup
       │  mts->tx_ring.head = next_head;
       │  // Ring doorbell:
       │  writel(head_idx, mts->bar + MTS_TX_KICK);
       │  spin_unlock(&mts->tx_lock);
       │  return NETDEV_TX_OK;

mts_tx_complete()  [called from NAPI poll]
  └─> while (desc[tail].ctrl & MTS_DESC_OWN == 0) {  // hardware cleared OWN
         skb = mts->tx_ring.skb[tail];
         dma_unmap_single(&pdev->dev, ..., DMA_TO_DEVICE);
         dev_kfree_skb_any(skb);
         mts->tx_ring.skb[tail] = NULL;
         tail = (tail + 1) % ring_size;
         mts->stats.tx_packets++;
     }
     if (netif_queue_stopped(dev) && (free_descs > wake_threshold))
         netif_wake_queue(dev);
```

### RX (alloc → rx_poll → refill)

```
mts_rx_refill()  [called at init and after consuming packets]
  └─> for entry from rx_ring.tail to rx_ring.head:
         skb = netdev_alloc_skb(dev, mts->rx_buffer_size);
         mapping = dma_map_single(&pdev->dev, skb->data, mts->rx_buffer_size, DMA_FROM_DEVICE);
         desc->addr = cpu_to_le32(mapping);
         desc->ctrl = cpu_to_le32(MTS_DESC_OWN);   // give to hardware
         if (wrap) desc->ctrl |= MTS_DESC_WRAP;

mts_rx_poll()  [called from NAPI poll, up to budget packets]
  └─> while (work_done < budget) {
         desc = &rx_ring.desc[rx_ring.tail];
         if (desc->ctrl & MTS_DESC_OWN) break;    // hardware still owns it
         rmb();  // ensure desc fields visible after OWN check
         // Extract length from desc->ctrl
         len = le32_to_cpu(desc->ctrl) & MTS_DESC_LEN_MASK;
         // Unmap and transfer ownership of skb:
         dma_unmap_single(&pdev->dev, addr, len, DMA_FROM_DEVICE);
         // For now: copy approach (simpler):
         skb_put(skb, len);
         skb->protocol = eth_type_trans(skb, dev);
         netif_receive_skb(skb);
         // Alloc replacement:
         mts_rx_refill_one(mts);   // alloc new skb, give descriptor back to HW
         work_done++;
     }
     mts_rx_refill(mts);   // batch refill any remaining empty slots
```

### MTS descriptor format (16 bytes, from Orbis RE + macb model)

```
Offset  Size  Field
0x00    32    addr_lo    — DMA buffer address (low 32 bits)
0x04    32    ctrl        — bit 31: OWN (1=HW, 0=SW)
                          — bits 15:0: buffer length (TX) or frame length (RX)
                          — TX: bit 30 FS (first segment), bit 29 LS (last segment)
                          — RX: reserved
0x08    32    addr_hi    — DMA buffer address (high 32 bits, for 64-bit DMA)
0x0C    32    reserved   — padding / future use
```

This maps directly to macb's `struct macb_dma_desc` (also 16 bytes: addr + ctrl
+ ... with OWN in bit 0 of addr for RX, and in ctrl for TX). The MTS hardware
uses bit 31 of ctrl for OWN throughout, which is cleaner.

---

## 6. ndo_open / ndo_stop Skeleton

```c
static int mts_ndo_open(struct net_device *dev)
{
    struct mts *mts = netdev_priv(dev);
    int err;

    /* Allocate and init DMA rings */
    err = mts_alloc_rings(mts);
    if (err) return err;

    mts_init_rings(mts);  /* fill RX descs, clear TX descs */

    /* Request MSI */
    err = pci_request_msi_range(mts->pdev, 1, 1);
    /* fall back to legacy if MSI fails */
    err = request_irq(mts->pdev->irq, mts_isr, IRQF_SHARED, DRV_NAME, dev);
    if (err) goto err_free_rings;

    napi_enable(&mts->napi);

    /* Enable interrupts */
    writel(MTS_IRQ_ENABLE_FULL_VAL, mts->bar + MTS_IRQ_ENABLE_FULL);
    writel(MTS_IRQ_MASK_FULL_VAL, mts->bar + MTS_IRQ_MASK);

    /* Kick RX engine */
    writel(readl(mts->bar + MTS_RX_KICK) | MTS_ENGINE_START, mts->bar + MTS_RX_KICK);

    netif_start_queue(dev);
    return 0;

err_free_rings:
    mts_free_rings(mts);
    return err;
}

static int mts_ndo_stop(struct net_device *dev)
{
    struct mts *mts = netdev_priv(dev);

    netif_stop_queue(dev);
    napi_disable(&mts->napi);

    /* Disable interrupts */
    writel(0, mts->bar + MTS_IRQ_ENABLE_FULL);
    writel(0, mts->bar + MTS_IRQ_MASK);

    free_irq(mts->pdev->irq, dev);

    /* Stop TX/RX engines */
    writel(readl(mts->bar + MTS_RX_KICK) & ~MTS_ENGINE_START, mts->bar + MTS_RX_KICK);
    writel(readl(mts->bar + MTS_TX_KICK) & ~MTS_ENGINE_START, mts->bar + MTS_TX_KICK);

    mts_free_rings(mts);
    return 0;
}
```

---

## 7. Key Differences from macb to Account For

| Aspect | macb (template) | ps4_mts (our driver) |
|---|---|---|
| Bus | Platform (DT) | PCI (pdev) |
| IRQ | Platform IRQ | MSI single vector |
| DMA addr width | 32-bit (MACB) or 64-bit (GEM) | 64-bit (write addr_lo/hi to BAR+0x3c/0x44) |
| Ring base register | RBQP/RBQPH, TBQP/TBQPH | See msk_init_hw: BAR+0x44/0x40 for RX, BAR+0x3c/0x40 for TX |
| Ring size | 512 default | 256 (from msk_init_hw: 0x100 entries) |
| Descriptor OWN | bit 0 in addr (RX), bit in ctrl (TX) | bit 31 in ctrl (0x80000000) per Orbis RE |
|NUM queues | 1 to 8 | 1 |
| NAPI | Separate napi_rx and napi_tx per queue | Single napi (RX+TX done + link change) |
| Link management | phylink | Poll BAR+0x04 (no PHY interrupt yet) |

### MTS-specific DMA ring registers (from Orbis RE)

```
TX descriptor base:  BAR+0xe88 (lo32), BAR+0xe8c (hi32)  — in msk_init_hw
RX descriptor base:  BAR+0x44  (lo32), BAR+0x40  (lo32)  — in mts_init_rings_kick
                       BAR+0x48  (lo32), BAR+0x40  (lo32)  — alt RX config
TX ring size mask:    BAR+0xe84 = 0x7ff  (2048 - 1 = 0x7ff, but 0x100 entries in init code)
TX kick:              BAR+0x34 (bit 4 = TX engine start)
RX kick:              BAR+0x34 (bit 0 = RX engine start), or separate BAR+0x38
```

Note: msk_init_hw uses TX ring at softc+0xe80 offset area, RX ring at
softc+0x3060 area. The actual BAR registers differ from macb's simple
RBQP/TBQP pair — we'll need to map MTS's descriptor ring base registers
carefully from the decompiled offsets.

---

## 8. Summary — Minimum LOC Estimate

| Component | Estimated LOC |
|---|---|
| Struct definitions (mts, mts_ring, mts_desc) | ~60 |
| PCI probe/remove | ~80 |
| Netdev ops (open/stop/xmit/set_rx_mode/stats/macos) | ~120 |
| NAPI poll + ISR | ~100 |
| TX path (start_xmit + tx_complete) | ~100 |
| RX path (rx_poll + rx_refill) | ~120 |
| Ring alloc/free/init | ~80 |
| MAC init (existing code, extended) | ~200 |
| Link poll | ~50 |
| **Total** | **~910 LOC** |

For reference, macb_main.c is 5677 LOC but supports 5+ SoC variants, multi-queue,
TSO, phylink, SGMII, PTP, WoL, etc. Our phase-3 driver needs only the
single-queue path which is about 25% of macb.