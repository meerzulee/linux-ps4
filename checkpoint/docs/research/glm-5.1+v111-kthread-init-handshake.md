# v111: gbe:ctrl kthread + init handshake analysis

**Date**: 2026-05-13 (updated)
**Agent**: glm-5.1
**Source**: Ghidra MCP decompiles of gbe:ctrl (0xffffffffc85f1e80), FUN_ffffffffc85f1890,
mts_intr (0xffffffffc85edcf0), mts_ifup (0xffffffffc85ec940)

## gbe:ctrl is a ONE-SHOT, not a loop

gbe:ctrl (FUN_ffffffffc85f1e80) runs once per interface UP:
1. `mts_init_rings_kick(parent_device)` — set up rings, BAR+0x34|=1, BAR+0x38|=1, BAR+0x54=shadow
2. If switch mode (`softc+0x30dc != 0`): kernel flag set + ioctl 0x80206910
3. If link-wait needed (`softc+0x30e0 != 0`): poll BAR+0x04 bit 0 up to 70x, send mgmt frame type 0x800b
4. Call FUN_ffffffffc85f2250 (post-link: MDIO reads, mgmt frames 0x800b + 0x600b, FUN_ffffffffc85f1010)
5. Clear softc+0x3099 bit 4
6. **BAR+0x54 &= ~0x1000** (clear bit 12 of IRQ mask)
7. Return

gbe:phy_ctrl likewise runs once, polls PHY state, and returns.

## FUN_ffffffffc85f1890 — the mgmt frame sender + TX kicker

This function:
1. Allocates a management frame (ICC message to switch)
2. Calls FUN_ffffffffc85f1aa0 to send it
3. **On success: BAR+0x34 |= 4** (TX kick bit!)
4. Waits for response (up to 1000 iterations)

This means every successful mgmt frame send ends with a TX kick.
Our driver's ndo_start_xmit already does `BAR+0x34 |= MTS_KICK_PKT (0x04)`,
so this particular write is already covered.

## The 0x40000 init handshake — the actual mechanism

In Orbis `mts_intr`:

### Phase 1: First-ever interrupt
```c
if (softc->first_irq == 0) {
    softc->first_irq = 1;
    BAR+0x204 = 0x10001388;  // enable master IRQ block
    BAR+0x54 = 0x7bfffe;     // mask: all except bit 0 and bit 23
}
```

### Phase 2: Every interrupt (loop)
```c
status = BAR+0x50;           // read IRQ status (W1C)
BAR+0x50 = status;           // write-back to clear (W1C)

// ... handle NAPI, link change, TX complete, RX ...

// INIT COMPLETE HANDSHAKE:
if ((status & ~softc->irq_mask & 0x40000) && (softc->first_irq == 1)) {
    softc->first_irq = 0;    // handshake done
    BAR+0x204 = 0;            // DISABLE master IRQ block
    BAR+0x54 = softc->irq_shadow_mask;  // restore normal mask
}

// PHY_CTRL THREAD WAKE (bit 12):
if ((status & 0x1000) && (softc->switch_mode != 0)) {
    softc->flags0 |= 0x10;
    BAR+0x54 |= 0x1000;      // re-enable bit 12 in mask
    sx_xlock(&softc->phy_ctrl_lock);
    softc->phy_ctrl_flags |= 0x10000;  // wake phy_ctrl
    sx_unlock(&softc->phy_ctrl_lock);
    sx_wakeup(&softc->phy_ctrl_lock);
}
```

### What happens in our driver (wrong)

1. We write BAR+0x204 = 0x10001388 at probe time and LEAVE IT ON
2. We write BAR+0x54 = 0x007bbffe (mask bit 18 OUT)
3. Device asserts bit 18, we never ACK it → 5kHz storm
4. We never clear BAR+0x204 → master block stays enabled
5. We never toggle BAR+0x54 through the handshake sequence

### What SHOULD happen

The 0x40000 bit is the device's "init complete" signal. The handshake protocol is:

1. Driver enables master IRQ block (BAR+0x204) with bit 18 in mask
2. Device finishes init → asserts IRQ with bit 18 set
3. Driver sees bit 18 → clears master block (BAR+0x204=0) and restores mask
4. Device acknowledges by de-asserting bit 18

**This is a one-shot init-complete handshake.** Our driver needs to:
- Include bit 18 in the initial mask
- On first bit-18 assertion: clear BAR+0x204=0, restore BAR+0x54=saved_mask
- After handshake completes, bit 18 should stop firing

### Why bit 18 keeps firing

We mask it out (0x7bbffe), so the device sees its interrupt was not acknowledged.
The interrupt status remains asserted because we W1C-ack it but never clear the
master block. The device thinks "driver never processed my init-complete signal"
and re-asserts it. This is a classic "missing ACK" loop.

## BAR+0x208 and BAR+0x210 (= 1 in Orbis)

Neither is written by any decompiled MTS function. They are likely set by:
- FreeBSD's bus_setup_intr infrastructure (MSI-X vector enable?)
- Or the DMA allocation path (bus_dmamap_create writeback)
- Or FreeBSD's PCI resource activation (bus_alloc_resource for the 2nd/3rd BAR)

In Linux, our driver requests only BAR0 (0x1000 bytes). If the device has
additional BARs for ICC/shared-memory, we'd need to map those too.
The addresses 0x208 and 0x210 could be ICC doorbell registers that get
enabled during MSI setup.

**Speculative approach**: Try writing BAR+0x208=1 and BAR+0x210=1 in probe
after IRQ setup, matching Orbis state. 30-second hotswap test.

## The softc+0x3178 / softc+0x31c8 wake mechanism

In `mts_ifup`:
```c
sx_xlock(&softc->ctrl_lock);    // softc+0x3178
softc->ctrl_flags |= 0x10000;   // wake gbe:ctrl
sx_xunlock + sx_wakeup;

if (softc->link_wait_needed == 0) {  // softc+0x30e0 == 0
    sx_xlock(&softc->phy_ctrl_lock); // softc+0x31c8
    softc->phy_ctrl_flags |= 0x10100; // wake gbe:phy_ctrl
    sx_xunlock + sx_wakeup;
}
```

These are FreeBSD sx_lock/sleepable mutex structures. The 0x10000/0x10100
are wake flags — not BAR register writes. Our Linux driver doesn't need
to replicate this mechanism (we use kthreads/worker queues directly).

## Best-bet patch: implement the 0x40000 handshake

```c
/* In mts_intr, add first-IRQ tracking */
static int first_irq = 0;

irqreturn_t mts_intr(int irq, void *dev_id)
{
    struct mts *mts = dev_id;
    u32 status;

    /* Phase 1: On very first interrupt, enable full IRQ block + mask */
    if (!first_irq) {
        first_irq = 1;
        writel(0x10001388, mts->bar + MTS_IRQ_ENABLE_FULL);
        writel(0x7bfffe, mts->bar + MTS_IRQ_MASK);
    }

    status = readl(mts->bar + MTS_IRQ_STATUS);
    if (!status)
        return IRQ_NONE;
    writel(status, mts->bar + MTS_IRQ_STATUS);
    (void)readl(mts->bar + MTS_IRQ_STATUS);

    /* Phase 2: INIT COMPLETE handshake (bit 18) */
    if ((status & 0x40000) && first_irq == 1) {
        first_irq = 0;
        writel(0, mts->bar + MTS_IRQ_ENABLE_FULL);  /* disable master block */
        writel(MTS_IRQ_MASK_FULL_VAL, mts->bar + MTS_IRQ_MASK); /* restore normal */
        return IRQ_HANDLED;
    }

    /* ... normal handling ... */
}
```

## Secondary experiments (30sec each via hotswap)

| Priority | Write | Rationale |
|----------|-------|-----------|
| P1 | 0x40000 handshake in ISR | Most likely root cause |
| P2 | BAR+0x08 \|= 0x08000000 | Orbis has bit 27 we don't |
| P3 | BAR+0x208 = 1 | Unsourced enable in Orbis |
| P4 | BAR+0x210 = 1 | Unsourced enable in Orbis |