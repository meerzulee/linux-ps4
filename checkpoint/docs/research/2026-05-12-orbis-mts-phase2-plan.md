# MTS phase 2 plan — sky2 + custom SMI + mainline MT7531 driver (2026-05-12)

This doc supersedes parts of `2026-05-12-orbis-mts-driver-RE.md`.  After
deeper RE of the Orbis driver stack, the picture is clearer than v77/v77b
suggested.

## Revised understanding

The Orbis Baikal GBE driver is **TWO FreeBSD drivers stacked**:

```
PCI 0x104d:0x90d8 ("Baikal GBE controller")
 │
 ├─ baikal_gbe / if_msk parent driver  (FUN_ffffffffc8511100)
 │    │  Source path: W:\Build\J02688428\sys\freebsd\sys\dev\msk\if_msk.c
 │    │  This is FreeBSD's stock Marvell Yukon-2 driver, customized for PS4.
 │    │
 │    ├─ Sets up status ring (4 KB, BAR+0xE80 family registers)
 │    ├─ MSI alloc + bus_setup_intr(FUN_8512b00 = msk_intr)
 │    ├─ Reads PCI BAR0+0x11b for chip ID byte; expects 0xBD
 │    ├─ Reads PHY id at addr 0 reg 2/3 — expects OUI 0x5043 (= Marvell
 │    │  00-50-43, the standard Marvell OUI) and model 0x2b.  If the
 │    │  match succeeds runs L2 switch VLAN config; otherwise prints
 │    │  "Skip VLAN config OUI: 0x%04x, Model: 0x%04x" and tries a
 │    │  GPIO-style switch reset (write 1/2 to BAR+0xF04 with 12ms +
 │    │  500ms delays) and retries the ID read once.
 │    ├─ Allocates a child device "PORT_A"
 │    └─ bus_generic_attach() → spawns mts child
 │
 └─ mts / if_mts.c child driver  (FUN_ffffffffc85ec030 — our v77 RE)
      │  Source path: W:\Build\J02688428\sys\freebsd\sys\dev\mts\if_mts.c
      │  Per-port ethernet interface that hangs off the msk parent.
      │
      ├─ Allocates TX/RX DMA rings (256 entries each, 16-byte descriptors)
      ├─ Reads MAC address from SBL ("node 0" / "node 1")
      ├─ Sets up gbe:ctrl + gbe:phy_ctrl kthreads (allocated elsewhere —
      │  attach only calls kthread_resume in mts_ifup)
      ├─ Runs mts_mac_init: clears master reset, sets PCIe MPS to 2048
      │  if needed, runs SMI MDIO PHY init at BAR+0x00, configures
      │  MAC address regs, multicast filter
      └─ bus_setup_intr(FUN_85edcf0 = mts_intr) — second ISR for the
         port that walks TX/RX rings on bit 0x40, 0x80, 0x1000
```

So our v77/v77b driver implemented *only* the child (`mts_attach` mimic)
without the parent's Yukon-2-style HW bring-up.  That's why SMI works at
boot (the running Linux kernel inherited Orbis's parent setup) but dies
after ~1 min (no kthread to keep MAC clocks alive, no ISR to enable the
IRQ block).

## Why the PHY-ID `0x03a29441` mismatch matters less than it looked

The OUI check in the msk parent (`uVar28 == 0x5043 && uVar26 & 0x3f0 == 0x2b0`)
is for **the switch chip's identification**, not the per-port PHY.  Sony's
older Baikal revisions had a Marvell 88E6XXX switch chip whose PHY ID at
MDIO addr 0 reports OUI 0x5043 / model 0x2b.  Our PS4 has the newer
revision where Sony replaced the switch IC with **MediaTek MT7531**
(OUI bits 0xE8A65 / model 0x11, encoding PHY ID 0x03a29441).

The msk parent's response to the mismatch is just "Skip VLAN config" —
not fatal.  The rest of the parent init (status ring, ISR, etc.) still
runs.  So we don't need to fake the Marvell OUI; we just need to handle
the case where the switch is MT7531.

## Why sky2 (Linux's msk) was almost the right path all along

Linux's `drivers/net/ethernet/marvell/sky2.c` IS the upstream port of
FreeBSD's `if_msk.c`.  Sony's parent is a downstream fork.  v69's MDIO
scan dead-end happened because sky2 reads PHY via `GM_SMI_CTRL` at
`BAR + port*0x80 + 0x80` (= BAR+0x2880) — but Sony moved the SMI MDIO
to a custom controller at **BAR+0x00**.  Everything else in sky2 — TX
ring, RX ring, ISR, Yukon-PRM chip path — likely matches Baikal closely
enough to work.

**The phase-2 implementation should be:**

1. Drop the standalone `ps4_mts.c` driver.  Restore sky2's Baikal entry
   in `sky2_id_table` (remove the `#ifdef CONFIG_PS4_MTS` we added in v77).
2. Modify sky2 so that on PS4 Baikal:
   - Force `chip_id` to `YUKON_PRM` (the v67 patch — keep it).
   - Replace `gm_phy_write` / `__gm_phy_read` callees with PS4-specific
     SMI accessors that talk to BAR+0x00 using the C22/C45 protocol from
     our v77 RE.
   - Skip Yukon's `sky2_phy_init` — the SMI controller and the MT7531
     switch don't need it.
   - Register a phylib mdio_bus that exposes the SMI accessor.
3. Hook mainline `drivers/net/phy/mediatek/mtk-ge.c` (MTK_GPHY_ID_MT7531)
   as the PHY driver for that bus.  Mainline already knows how to drive
   MT7531's per-port PHY — no new PHY driver needed.
4. Optionally: hook mainline `drivers/net/dsa/mt7530.c` (the MT7531
   switch driver) so the chip's switch fabric is configured properly.
   This is needed if PORT_A alone doesn't get a usable link path.

This is significantly less work than completing the from-scratch
`ps4_mts.c` driver because sky2 already does the Yukon-2 register
choreography, RX/TX descriptor ring management, and ISR handling.

## Action items for the next session

In rough order:

| # | Task | Effort |
|---|---|---|
| 1 | Revert v77b: remove `#ifndef CONFIG_PS4_MTS` from sky2 (Baikal entry restored), keep `ps4_mts.c` stub disabled. | ~10 lines |
| 2 | Add a Baikal-only branch in `gm_phy_write` and `__gm_phy_read` that calls a new `sky2_baikal_smi_*` helper for BAR+0x00 access (C22 protocol from v77). | ~80 lines |
| 3 | Add a `sky2_baikal_phy_init` no-op (or copy mts_mac_init's pre-PHY register writes) that skips Yukon's `sky2_phy_init`. | ~30 lines |
| 4 | Register an MDIO bus in `sky2_probe` for Baikal port 0 so phylib can find the PHY. | ~50 lines |
| 5 | Enable mainline `CONFIG_MEDIATEK_GE_PHY=y` and confirm MT7531 PHY driver attaches. | config |
| 6 | If link still doesn't come up: enable `CONFIG_NET_DSA_MT7530=y` and wire up DSA framework. | config + small glue |
| 7 | Boot test, watch UART for `sky2 0000:00:14.1 eth0: link UP at 1000Mbps full-duplex`. | runtime |

## Open questions remaining for Ghidra

- The `gbe:ctrl` and `gbe:phy_ctrl` kthreads: their CREATE site is still
  unidentified.  They're resumed in `mts_ifup` (FUN_85ec940) so they
  exist by then.  Tracing what they actually DO is necessary if SMI
  durability turns out to require something beyond the IRQ block enable.
- `mts_mac_init`'s efuse reads (`FUN_8764760` with offsets 0x5c-0x6c)
  drive PHY trim register writes.  For MT7531 these are likely a no-op
  (we don't have a Marvell PHY); confirm by checking what the trim
  function actually writes.
- The "Skip VLAN config" code path's `FUN_8512b00` (msk_intr) and
  `FUN_8513c60` (Marvell L2 switch VLAN setup) — confirm we don't
  need to mimic any of this on MT7531.

## Ghidra anchor points (new this round)

```
FUN_ffffffffc8511100  →  baikal_gbe_attach    (= msk parent attach)
FUN_ffffffffc8511d50  →  msk_init_hw          (Yukon-2 HW bring-up)
FUN_ffffffffc8512b00  →  msk_intr             (parent ISR)
FUN_ffffffffc85ec940  →  mts_ifup
FUN_ffffffffc85ef1b0  →  mts_init_rings_kick  (writes TX/RX desc ptrs + kicks)
FUN_ffffffffc8788e50  →  pcie_get_mrrs        (returns current Max Read Request Size)
FUN_ffffffffc8788f50  →  pcie_set_mrrs        (sets Max Read Request Size)
FUN_ffffffffc8513a70  →  msk_phy_read         (used for switch-chip ID detection)
FUN_ffffffffc8513c60  →  msk_l2switch_vlan_init  (Marvell-only VLAN setup, skip on MT7531)
```
