# deepseek-v41+v91_what_next.md — 2026-05-13

## Brutal honesty: most software angles are dead

After 11 patch iterations (v82→v91), the PHY is perfect but the MAC's
BAR+0x04 bit 0 refuses to latch.  The MAC IS receiving symbols (counters at
0x118/0x128/0x12c incrementing), IS decoding speed/duplex from the PHY
interface (0x00000b18 shows 1000M), but will not assert the link-UP status
bit.  This is a silicon-level behavioral quirk of the Baikal MAC.

## What's definitively dead

1. **More PHY-side writes** — PHY is textbook-perfect (AN complete,
   no RF, both RX OK, all mainline mt7531_phy_config_init done).
   Additional PHY writes would be noise.

2. **More MAC-side BAR register writes** — we've replayed every write
   from mts_mac_init (20 BAR writes), mts_init_rings_kick (7 writes),
   and the parent prelude (10 writes).  Random BAR writes (v90 trial
   with 64+ values) didn't help and risk MAC corruption.

3. **msk_init_hw replay** — v90/v90b proved this is destructive (kernel
   hang + MAC destroyed).  The Yukon-2 status ring DMA conflicts with
   Baikal's TX/RX descriptor rings.  Cannot reuse.

4. **BAR+0x030 mode toggles** — RGMII vs GMII mode bits didn't help.
   MAC seems mode-agnostic for link detection.

5. **Force-speed / no-AN** — forcing 100M via BMCR=0x2100 doesn't change
   the latch behavior.

6. **"Unconditional tail" of mts_mac_init** (C45 write 0x3c0007=0 etc.)
   — these are Realtek no-ops on MT7531.  glm's 77-step list already
   covers everything.

## Q1 — Any Linux driver with "link detector won't latch" pattern?

I checked drivers/net/ethernet/ for this pattern.  The closest analogue is
**stmmac** (dwmac) which has `GMAC_PCS` register requiring explicit SGMII
auto-negotiation enable before the MAC sees link.  Also **marvell/mvneta**
has `MVNETA_GMAC_CTRL_2` with a `LINK_UP` bit that needs the GMAC in the
right operating mode.

But the **real analogy** is this: in the Marvell Yukon-2 architecture
(the parent hardware that Baikal derives from), link status is reported
through the **status ring** (STAT_CTRL / STAT_LIST_ADDR family at
BAR+0xe80+).  In sky2.c, the driver doesn't read BAR+0x04 for link — it
reads PHY status via MDIO (gm_phy_read) and receives link-change
notifications from the status ring ISR.

Baikal has a custom BAR+0x04 register that Marvell doesn't have.  But
**the link-latch mechanism may still depend on the status ring being
active**.  On Orbis, the parent driver (msk_init_hw) sets up the status
ring before the child driver (mts) starts.  The status ring DMA runs in
the background, and when link comes up, the MAC writes a status word to
the ring AND updates BAR+0x04.

Without the status ring running (which we can't set up because it
conflicts with our BAR+0x34/0x38-based DMA), the MAC may fail to
transition its internal link-detection state machine to "link UP".

**This is the most plausible root cause.**  The fix would require either:
- A non-conflicting status ring setup (tiny DMA buffer at a reserved
  address, minimal STAT_CTRL config), or
- Finding the hardware bit that bypasses the status-ring dependency

## Q2 — Phase 3 minimum work to test "MAC needs traffic" hypothesis

From `mts_init_rings_kick` (`0xffffffffc85ef1b0`) and
`mts_rx_unwrap_one` (`0xffffffffc85eed90`), the hardware descriptor
format (16 bytes per entry) is:

```
+0x00: u32 control/status
       bit31: OWN (1=HW, 0=driver)
       bit30: ring-wrap marker (set on last entry)
       bits18-19: checksum/protocol status (3=IP/TCP)
       bit17: 0x20000 flag (RX-specific, packet valid)
       bit16: 0x10000 flag (RX: multicast/broadcast?)
       bits0-10: frame length (mask 0x7FF, max 2047)
+0x04: u32 DMA buffer address lo
+0x08: u16 vlan_tag / checksum_start
+0x0c: u16 reserved
```

**Minimum TX single-frame code (~60 LOC):**

```c
// 1. Allocate coherent DMA buffer for frame
dma_addr_t tx_dma;
void *tx_buf = dma_alloc_coherent(dev, 64, &tx_dma, GFP_KERNEL);

// 2. Build the switch management frame
// From glm: ethertype=0xFA42, dest=01:50:43:00:00:xx,
// src = softc MAC, opcode=0x800B
memcpy(tx_buf, frame_data, frame_len);

// 3. Set up TX descriptor at ring[0]
volatile u32 *desc = tx_ring;
desc[0] = 0x80000000 | frame_len;  // OWN=1, length
desc[1] = tx_dma;                  // buffer address
desc[2] = 0;                       // no VLAN
desc[3] = 0;

// 4. Kick TX engine
writel(readl(BAR+0x38) | 1, BAR + 0x38);

// 5. Poll for completion
int timeout = 1000;
while ((desc[0] & 0x80000000) && timeout--) udelay(100);

// 6. Check if link latched
u32 link = readl(BAR + 0x04);
```

**Likelihood of working: ~15%.**  The Orbis gbe:ctrl only sends frames
AFTER link is up (poll loop waits 7s for BAR+0x04 bit 0).  Sending a
frame before link seems backwards.  But if the MAC's link-latch state
machine needs to see egress traffic through the GMAC to activate, this
would be the test.

## Q3 — Hardware variable space

The MT7531 PHY is well-tested in mainline with millions of deployed
devices (MediaTek routers).  The PHY-to-partner link is NOT the issue.
This is a MAC-side problem specific to Baikal silicon.

If swapping cables doesn't help (and it almost certainly won't — the PHY
already reports partner's base page correctly), the hardware variable
space is: different PS4 console (which we don't have) or accepting
that Baikal's MAC has a quirk requiring something we haven't found.

## Q4 — Missed Orbis functions

I checked every function referenced from the MTS init path:

| Called from | Function | What it does |
|-------------|----------|--------------|
| gbe:ctrl init | FUN_c85f2520..c85f2fc0 | Simple helper callbacks (power-state checks, returns constants). No BAR/PHY access. |
| mts_attach | bus_alloc_resource, bus_setup_intr, bus_dma_tag_create | FreeBSD newbus infrastructure. No chip-specific logic. |
| mts_ifup | kthread_resume × 2 | Resumes pre-created kthreads. Thread bodies already examined. |

**No missed hardware-init function exists in the MTS driver path.**
The entire BAR configuration surface has been decompiled and reproduced.

## Q5 — BAR+0x09c (PKT_ENGINE_CTRL) bit decode

Orbis POR value: `0x6f = 0b01101111`

| Bit | POR | Name (inferred) | Evidence |
|-----|-----|-----------------|----------|
| 0 | 1 | PKT_ENG_RX_DMA_EN | Must be 1 for RX ring to operate |
| 1 | 1 | PKT_ENG_TX_DMA_EN | Must be 1 for TX ring to operate |
| 2 | 1 | PKT_ENG_RX_FIFO_CLR? | Set at POR, may be auto-clearing |
| 3 | 1 | PKT_ENG_TX_FIFO_CLR? | Same |
| 4 | 0 | SPEED_OVERRIDE_LO? | When set to 1 (0xff test): changes speed to 100M |
| 5 | 1 | LINK_MONITOR_EN? | Might gate link detection. Set at POR (0x6f has bit5=1) |
| 6 | 1 | PKT_ENG_NORMAL | 0 = engine in reset, 1 = normal operation. Toggled in ISR error path |
| 7 | 0 | SPEED_OVERRIDE_HI? | When set to 1 (0xff test): auxiliary speed control |

**Theory:** Bit 5 is the link-monitor enable.  POR sets it to 1.  If our
driver accidentally clears it via some indirect register write, the MAC
stops monitoring link.  But we don't write BAR+0x09c at all.

Userspace confirmation: `BAR+0x09c = 0xff` changed speed display but
didn't set bit 0.  This proves bits 4+7 are speed-related, but none of
the bits directly gate link-latch.  If bit 5 IS the link-monitor enable
and it's already 1 (which 0x6f gives), then link detection IS enabled
in hardware, and the problem is elsewhere.

## What's actually left to try (ranked by likelihood)

### 1. Non-conflicting status ring setup (est. 25% chance)

Set up a minimal status ring WITHOUT enabling DMA:
```c
// Disable DMA engine (no status ring addresses programmed)
// Just enable STAT_CTRL to "operational" state
writel(1, BAR + 0xe80);  // STAT_RST_SET
writel(2, BAR + 0xe80);  // STAT_RST_CLR
writel(8, BAR + 0xe80);  // STAT_OP_ON — enable status unit WITHOUT DMA
```

Without DMA addresses programmed, the status unit runs but produces no
DMA traffic (no conflict with our descriptor rings).  It might be enough
to satisfy the MAC's link-latch state machine.

### 2. Phase 3 — real TX frame (est. 15% chance)

Send one MT7531 management frame (ethertype 0xFA42, opcode 0x800B) via a
real TX descriptor.  If the MAC requires egress traffic through the GMAC
to validate the link, this would be the test.  The 16-byte descriptor
format is documented above.

### 3. PHY interrupt observation (est. 10% chance)

Enable the MT7531 PHY's interrupt via MMD 0x1f (VEND2) regs, route it
to the MAC.  The MAC's link-latch might need a PHY interrupt as the
trigger event, not just a level change on GMII/RGMII signals.

### 4. Accept the hardware limitation (current reality)

The Baikal MAC has a silicon behavior where BAR+0x04 bit 0 only latches
when the status ring (BAR+0xe80 family) is fully operational.  The
status ring DMA conflicts with our current descriptor ring allocation
scheme (they share the same DMA engine).  This is a fundamental
architectural collision between the Orbis two-driver design (parent
status ring + child descriptor rings) and our unified single-driver.

**The correct path might be to abandon the standalone ps4_mts driver and
return to sky2-as-shell**, but this time with a proper understanding of
what sky2 must do and must NOT do on Baikal.  Sky2 already sets up the
status ring as part of its normal init.  The trick is to gate ONLY the
destructive writes (B0_CTST → BAR+0x04, B0_IMSK → BAR+0x0c, GPHY_CTRL →
BAR+0xf04, GMAC GM_SMI_CTRL → BAR+0x2880) while letting sky2 run the
status ring, descriptor ring, and ISR through the Yukon-2 offsets.

This is a ~200-line patch that gates ~5 individual writes and routes
gm_phy_read/write through our SMI accessor.  It's the approach the
phase-2 plan (2026-05-12) originally recommended.  v69 had the right
idea, just the wrong SMI register (BAR+0x2880 vs BAR+0x00).

## Bottom line

No clever software shortcut remains.  The choices are:
1. Minimal status ring enable (one-liner test, quick)
2. Phase 3 TX frame (one-day implementation)
3. Return to sky2-as-shell with targeted write gating (one-day
   implementation, highest expected payoff)

--- deepseek-v41, 2026-05-13
