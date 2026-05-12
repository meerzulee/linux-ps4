# deepseek-v41+v83_link_research.md — 2026-05-12

**Primary finding: sky2 never writes BAR+0x34 bit 0 (RX restart) or BAR+0x38
bit 0 (TX start) — the MAC engines stay stopped, link state is never latched at
BAR+0x04 bit 0.  Orbis starts these engines in `mts_init_rings_kick` at the end
of `mts_ifup`.**

## The Orbis link bring-up sequence (FULL trace)

### mts_attach (FUN_c85ec030) — runs at PCI probe
1. Allocates ~12KB softc, populates `softc+0x612 = device_t`
2. Reads MAC from SBL "node 0" (primary) and "node 1" (secondary) into
   `softc+0x30d0` and `softc+0x30d6`
3. Sets `softc+0x60e = &memory_resource_type`
4. bus_alloc_resource(BAR) → stores handle at `softc+0x60d`
5. bus_alloc_resource(IRQ) → stores handle at `softc+0x60f`
6. bus_dma_tag_create ×5 for TX ring, RX ring, TX/RX descriptor pools
7. **Calls `mts_mac_init(softc)` RIGHT HERE — first init at attach time**
8. bus_setup_intr(param_1, IRQ_handle, 0x204, 0, mts_intr, softc, &tag)
   → registers mts_intr (FUN_c85edcf0) as ISR

### mts_ifup (FUN_c85ec940) — runs when interface is configured UP
```c
mts_mac_init(lVar4);                                    // second init pass
*puVar1 = *puVar1 & 0xffffffbf;                         // clear IFF_OACTIVE
mts_init_rings_kick(*(undefined8 *)(lVar4 + 0x30a0));   // DMA + engine start
kthread_resume(gbe:ctrl);    // softc+0x3150
if (carrier_polling_not_disabled)
    kthread_resume(gbe:phy_ctrl); // softc+0x31a0
```

### mts_mac_init end-of-function register state

After all PHY poke sequences (efuse-gated C45, Realtek C22 magic pokes) and
MAC register writes, the final register state is:

| Offset | Final value / operation |
|--------|------------------------|
| BAR+0x04 | `saved_val & 0x7fffcfff` (clear bits 12,13,18,19,31) |
| BAR+0x08 | `val \| 0x07597C00` (MAC_TX_EN, MAC_RX_EN, checksum, jumbo, VLAN, flow_ctrl) |
| BAR+0x0c | `val & ~0x80` (clear bit 7 = "init mode off") |
| BAR+0x10 | `(val & 0xffffff6e) \| 0x81` (set bits 0,7; clear bit 4) |
| BAR+0x14 | MAC addr [0:3], byte-swapped |
| BAR+0x18 | MAC addr [4:5], byte-swapped |
| BAR+0x1d4 | 1 |
| BAR+0x30 | 0x10100 |
| BAR+0x74 | 0x2277 |
| BAR+0x78 | `val & ~1` (clear bit 0 = "enable RX gate") |
| BAR+0x1c4 | 3 (multicast hash commit: broadcast accept) |
| BAR+0x1c8 | `val \| 0xC0000000` (promisc/multicast flags) |
| PHY reg 0 (BMCR) | `val \| 0x1200` **(AN enable + AN restart!)** |
| PHY reg 4 (ANAR) | `val & 0xf3ff` (clear bits 10,11) |

### The missing piece: mts_init_rings_kick (FUN_c85ef1b0)

This function is called from `mts_ifup` AFTER the second `mts_mac_init`.  It
initializes 256-entry TX and RX descriptor rings and then writes the following
BAR registers — these are **engine-start signals with no sky2 equivalent**:

```
BAR+0x44 = TX_desc_ring_DMA_addr_hi   (from softc+0x40)
BAR+0x3c = TX_desc_ring_DMA_addr_lo   (from softc+0x40)
BAR+0x48 = RX_desc_ring_DMA_addr_hi   (from softc+0x50)
BAR+0x40 = RX_desc_ring_DMA_addr_lo   (from softc+0x50)
BAR+0x34 |= 1     ← RX ENGINE START (bit 0 = RX_RESTART)
BAR+0x38 |= 1     ← TX ENGINE START (bit 0 = TX_START)
BAR+0x54 = IRQ_mask_shadow (softc+0x3098)
softc+0x309c = 0   (MAC_ENABLE flag to 0 → let ISR set it on first IRQ)
```

### Where sky2 diverges

Sky2 starts RX/TX via the Yukon-2 `Q_ADDR + Q_CSR = BMU_START` mechanism at
BAR+0x0B00+ range.  On Baikal these offsets either don't exist or map to
unrelated hardware.  **Sky2 never writes BAR+0x34 or BAR+0x38.**  The Baikal
MAC TX/RX engines never start.  Without the RX engine running, the MAC does
not monitor for link state changes — BAR+0x04 bit 0 (link up) never gets set
by hardware, even when the PHY completes auto-negotiation.

Supporting evidence:
- V82 confirmed SMI MDC works and phylib can read PHY registers.
- Live BAR readback in v79 showed `BAR+0x04 = 0x00000204`: bits 2,9 are set
  (speed=10M? autoneg active) but bit 0=0 (link down).
- MT7531 BMSR should show AN complete, but link-up doesn't propagate to the
  MAC register because the RX engine isn't running to latch it.

## MT7531-specific PHY init — what matches, what's missing

### Matches between Orbis and mainline mtk-ge.c

| Operation | Orbis (C45) | Mainline mtk-ge.c (C45) | Status |
|-----------|-----------|------------------------|--------|
| BMCR: AN enable + restart | C22 reg 0 `\| 0x1200` | `phy_start()` → `genphy_config_aneg()` | ✅ standard, phylib handles |
| AN advertisement | C22 reg 4 `& 0xf3ff` | `genphy_config_aneg()` | ✅ standard |
| TX delay select | Not explicitly set | MMD 0x1e reg 0x13, 0x14 | ⚠ Orbis skips, mtk-ge sets pair B/D to 0x4 |
| RXADC bias | Not set | MMD 0x1e reg 0xc6 | ⚠ mt7531-specific, Orbis doesn't set |
| Downshift enable | Not set | Extended page 1 reg 0x14 | ⚠ mtk-ge enables, Orbis skips |
| DSP ready time | Not set | Token Ring (0x1,0xf,0x17) | ⚠ mtk-ge adjusts, Orbis skips |
| PHY PLL enable | **Not set** | DSA driver: MMD 0x1f reg 0x403 | ❌ **Only DSA driver does this** |

### Critical gap: PHY core PLL (MDIO_MMD_VEND2, CORE_PLL_GROUP4)

mt7531_setup (DSA switch driver, NOT the PHY driver) enables the PHY core PLL:
```c
val = read_c45(control_phy, MDIO_MMD_VEND2, 0x403);
val |= BIT(6) | BIT(4);   // RG_SYSPLL_DMY2 | PHY_PLL_BYPASS_MODE
val &= ~BIT(5);            // clear PHY_PLL_OFF
write_c45(control_phy, MDIO_MMD_VEND2, 0x403, val);
```

Orbis does NOT write to `MMD 0x1f` register `0x403` in `mts_mac_init`.  The
PLL might have been enabled by the Orbis msk_parent_init or by bootloader
firmware.  If Linux reboots clean from Orbis (kexec), the PLL stays enabled.
But if we ever power-cycle or reset the switch (even accidentally via
BAR+0xf04), the PLL state is lost and must be re-programmed.

### Orbis's Realtek-specific C22/C45 pokes — all no-ops on MT7531

Orbis does 7+ blocks of extended-page C22 writes (page 0x52b5 → regs 0x10-0x12
→ restore page) and ~20 C45 writes to Realtek MMDs 0x1e/0x1f (registers 0x174,
0x175, 0x172, 0x173, 0x120, etc.).  These are Realtek efuse-trim calibration
values, gated by `efuse(0x6c) & 0x80800000 == 0x80800000` (check for Realtek
PHY).  On MT7531 this efuse check fails → bulk of C45 is skipped.  Remaining
unconditional C45 writes target registers that don't exist on MT7531
(0x189 in MMD 0x1e, 0x268 in MMD 0x1f, 0x3c0 in MMD 7) and are silently
ignored.

**Bottom line:** Orbis's PHY init is ~95% Realtek-specific no-ops on MT7531.
The only meaningful operations are BMCR AN restart, AN Advertisement config,
BAR register writes, and the BAR+0x34/0x38 engine-start writes.

## Kthread bodies — investigation result

The `gbe:ctrl` and `gbe:phy_ctrl` kthreads are NOT created in `mts_attach` or
`baikal_gbe_attach`.  The string "gbe:ctrl" at `0xffffffffc851115f` is a
mtx_init name, not a kthread_create argument.  Creation site is likely in a
module SYSINIT or in the FreeBSD ifnet layer during `if_alloc`.  kthread_resume
in mts_ifup uses handles stored at `softc+0x3150` and `softc+0x31a0` — these
are populated before ifup by unidentified code.  Further binary analysis
(search for `kproc_create` xrefs to the "gbe" string pool) is needed to find
the thread function bodies.

**Practical implication:** the kthreads' absence from Linux is likely NOT the
blocker.  Orbis's kthreads handle periodic link/carrier polling and PHY status
monitoring — functions that phylib and sky2's watchdog timer already cover.
The real blocker is the engine-start registers (BAR+0x34/0x38).

## The link-up state machine

1. PHY auto-negotiates with partner → AN complete
2. PHY asserts MDIO interrupt OR hardware drives BAR+0x04 bit 0 = 1
3. Baikal MAC raises BAR+0x50 bit 0x4 (link change IRQ)
4. mts_intr sees bit 0x4 → calls mts_link_change
5. mts_link_change reads BAR+0x04, extracts speed/duplex/flow_ctrl
6. Updates ifnet link state

Step 2 requires the MAC RX engine to be running (BAR+0x34 bit 0 = 1).
Without it, the link-up signal from the PHY doesn't propagate to BAR+0x04.

## Recommended v83 experiment

Add `sky2_write32(hw, 0x34, sky2_read32(hw, 0x34) | 1)` (RX start) and
`sky2_write32(hw, 0x38, sky2_read32(hw, 0x38) | 1)` (TX start) at end of
`sky2_hw_up` (after `sky2_rx_start` call, line ~1805 in sky2.c).  Also
set BAR+0x54 = 0x7bfffe (IRQ mask, from Orbis) and BAR+0x204 = 0x10001388
(IRQ block enable).  Then monitor BAR+0x04 bit 0 after `ip link set up` + wait
for phylib AN completion.

This is a 4-line patch.  If link comes up, we've found the last blocker.

--- deepseek-v41, 2026-05-12
