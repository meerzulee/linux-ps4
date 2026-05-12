# PS4 Baikal GBE — v83 link bring-up gap analysis
**Agent:** kimi-k2.6 (OpenCode)  
**Date:** 2026-05-12  
**Ghidra program:** `orbis-12.02.elf` (project `orbis-ps4-dump`)

---

## Lead finding: v82 missed the AN restart at the end of `mts_mac_init`

The Orbis `mts_mac_init` function (`FUN_ffffffffc85ecb60`) is ~450 lines.  The v82 "extended init" replayed only the **MAC-side BAR register writes** (offsets 0x08, 0x0c, 0x10, 0x30, 0x74, 0x78, 0x1d4, etc.).  It did **not** replay the full PHY/SMI sequence at the end of the function, which includes:

1. efuse-driven C45 trim writes to MMD 0x1e/0x1f (Realtek vendor MMDs)
2. Realtek extended-page poke sequence (`reg 0x1f = 0x52b5`, etc.)
3. **`BMCR |= 0x1200`** — restart autonegotiation

The last step is **generic to all Clause 22 PHYs**, including MT7531.  v82 left BMCR at `0x1040` (AN enabled, but not restarted).  AN was already marked "complete" (BMSR bit 5 = 1) from Orbis's prior boot state, but **link never latched** because the PHY was negotiating against stale parameters without a fresh restart.

---

## 1. What Orbis does between `mts_mac_init` and `mts_ifup`

### Sequence in `mts_attach` (`FUN_ffffffffc85ec030`)

After `mts_mac_init()` returns, `mts_attach` does **no additional PHY or link setup**:

```c
mts_mac_init(puVar5);                           // ~450 lines, ends with AN restart
lVar9 = FUN_ffffffffc8602cf0(param_1, "PORT_A"); // add child device
puVar5[0x615] = lVar9;
iVar4 = FUN_ffffffffc8605620(param_1);          // bus_generic_attach
if (iVar4 == 0) {
    iVar4 = FUN_ffffffffc86069f0(param_1, puVar5[0x60f], 0x204, 0,
                                 mts_intr, puVar5, puVar5 + 0x611);  // IRQ setup
}
```

So the **entire PHY bring-up is inside `mts_mac_init`**.  There is no hidden "second phase" in attach.

### What `mts_ifup` adds (`FUN_ffffffffc85ec940`)

```c
*(undefined8 *)(lVar4 + 0x32b0) = 0xa000000000000;  // some capability flags
mts_mac_init(lVar4);                                  // **runs AGAIN**
puVar1 = (uint *)(**(long **)(lVar4 + 0x30a0) + 0x1c8);
*puVar1 = *puVar1 & 0xffffffbf;                       // clear bit 6 (parent Yukon reg)
mts_init_rings_kick(*(undefined8 *)(lVar4 + 0x30a0)); // ring kick + parent hash init

// resume gbe:ctrl kthread — event mask = 0x10000
*(undefined4 *)(lVar4 + 0x3178) = 0x10000;
FUN_ffffffffc84dc270(lVar4 + 0x3178);

// resume gbe:phy_ctrl kthread — event mask = 0x10100
*(undefined4 *)(lVar4 + 0x31c8) = 0x10100;
FUN_ffffffffc84dc270(lVar4 + 0x31c8);
```

**Key:** `mts_ifup` runs `mts_mac_init` **a second time** when the interface is brought up.  This means the AN restart at the end of `mts_mac_init` happens **twice**: once at attach and once at `ifup`.  Our v82 driver only ran MAC register writes once at probe.

---

## 2. `mts_ifup` full decompile — SMI/BAR writes that enable link

`mts_ifup` itself does **no SMI or BAR writes beyond**:
- calling `mts_mac_init(lVar4)` (which does the full PHY + MAC init)
- clearing bit 6 at parent BAR+0x1c8 (Yukon hash init gate)
- calling `mts_init_rings_kick`

The `mts_init_rings_kick` (`FUN_ffffffffc85ef1b0`) function does DMA ring setup and sets the parent hash commit bit, but it does **not** touch the PHY or BAR+0x04.

**Conclusion:** There is no "magic enable" register write in `mts_ifup`.  The link bring-up is entirely driven by the PHY autonegotiation restarted inside `mts_mac_init`.

---

## 3. What gates linkreg bit 0?

**Linkreg bit 0 is purely passive.**  `mts_link_change` (`FUN_ffffffffc85eeb90`) only **reads** BAR+0x04:

```c
puVar6 = (uint *)(BAR_base + 4);
uVar3 = *puVar6;  // READ only, never write
if ((uVar3 & 1) == 0) {
    // link DOWN
} else {
    // link UP — decode speed/duplex from bits 2-4
}
```

There is **no MAC-side register that explicitly gates the link bit**.  It is driven directly by the PHY's MII link status signal into the Baikal MAC.

This is confirmed by the `gbe:phy_ctrl` thread logic: when link is down, it does not try to toggle any MAC register — it **only** manipulates PHY registers (reg 9, reg 4, reg 0) and restarts AN.

---

## 4. MT7531 vendor MMD writes — what Orbis does vs. what MT7531 needs

### What Orbis does (in `mts_mac_init`)

The efuse/trim block at the top of `mts_mac_init` does ~30 C45 writes to MMDs 0x1e and 0x1f:

| C45 addr | Value | Description |
|---|---|---|
| `0xe0001e` | `efuse[0x68] & 0x3f << 8` | Realtek trim |
| `0x115001f` | `efuse[0x68] >> 6 & 7` | Realtek trim |
| `0x174001e` | `... \| 0x8000` | Realtek vendor reg |
| `0x175001e` | `... \| 0x8000` | Realtek vendor reg |
| `0x172001e` | `...` | Realtek vendor reg |
| `0x12001e` | `...` | Realtek vendor reg |
| `0x16001e` | `...` | Realtek vendor reg |
| `0x17001e` | `...` | Realtek vendor reg |
| `0x18001e` | `...` | Realtek vendor reg |
| `0x19001e` | `...` | Realtek vendor reg |
| `0x20001e` | `...` | Realtek vendor reg |
| `0x21001e` | `...` | Realtek vendor reg |
| `0x22001e` | `...` | Realtek vendor reg |
| `0x96001e` | `0x8000` | Realtek vendor reg |
| `0x37001e` | `0x33` | Realtek vendor reg |
| `0x39001e` | `...` | Realtek vendor reg |
| `0x107001f` | `...` | Realtek vendor reg |
| `0x171001e` | `...` | Realtek vendor reg |
| `0x189001e` | `0x110` | Realtek vendor reg |
| `0x122001e` | `0xffff` | Realtek vendor reg |
| `0x268001f` | `0x7f4` | Realtek vendor reg |
| `0x3c0007` | `0` | ANEG MMD reg |
| `0x33001e` | `... & 0xefff` | Realtek vendor reg |

These are **Realtek RTL8211-family vendor registers**.  On MT7531 (MediaTek), MMD 0x1e exists but has **completely different register meanings** (MT7531 uses MMD 0x1e for SGMII/HSGMII PCS configuration, not PHY trim).

**Effect on MT7531:** The efuse/trim writes are effectively **no-ops or benign** because they write values that MT7531 doesn't use for link bring-up.  The critical write is the **generic C22 BMCR restart** at the end.

### What the `gbe:phy_ctrl` thread does for MT7531

The keepalive path reads C45 register `0xa2001e` (MMD 0x1e, reg 0xa2) as a **link-down detector**:

```c
mts_smi_cl45_read(param_1, 0xa2001e, &local_46);
if ((local_46 < 0) && (sc->event_phy_ctrl == 0)) {
    // local_46 < 0 means bit 15 set → link down
    // enter BMSR poll loop (up to ~200 iterations × 100ms = 20s)
    // if still down, restart AN
}
```

On Realtek PHYs, MMD 0x1e reg 0xa2 bit 15 is a vendor-specific link-down indicator.  On MT7531, this register likely has a different layout.  If bit 15 is **not** the link-down indicator, the gbe:phy_ctrl thread **skips the BMSR poll loop entirely** and does nothing on each 3-second heartbeat.

**This means Orbis's native driver might also be suboptimal on MT7531** — it relies on the C45 vendor register for fast link detection, but MT7531 doesn't implement the same vendor register map.  However, Orbis still gets link because:
1. `mts_mac_init` restarts AN at attach time
2. The partner responds to AN
3. Link comes up before the first heartbeat

In Linux, if AN is not restarted, link never comes up, and the heartbeat doesn't fix it because the C45 read doesn't detect link-down state.

---

## 5. The parent prelude (`FUN_c85131d0`) — what v82 got right

v82's `mts_parent_prelude()` correctly replicates `FUN_ffffffffc85131d0(param_1, 1)`:

```c
BAR+0xf10 = 1, then 2
BAR+0xf04 = 1, udelay(12000), BAR+0xf04 = 2, udelay(500000)
if (chip_id == 0xBD) {
    *(byte *)(param_1 + 0x49) |= 0x40;  // some capability flag
    *(undefined4 *)((long)param_1 + 0x4c) = 0x7d;
    if (PCI MPS == 0x10000) {
        BAR+0x60 = 0x32100
        BAR+0x64 = 6
        BAR+0x68 = 0x63b9c
        BAR+0x6c = 0x300
    } else {
        BAR+0x64 = 0x4000006
    }
}
BAR+0x120 = 1
BAR+0x11c &= 0xf8ff
```

This is the **switch-chip GPIO reset + clock config** that v82 already does.  It is required but not sufficient for link.

---

## 6. Disagreement with prior analysis

The v82 doc says: *"Possibilities: Cable not actually connected; MT7531 needs special vendor MMD writes; Orbis gbe:phy_ctrl does AN restart on link-down — our heartbeat only READS BMSR."*

**I agree with all three, but rank them differently:**

1. **AN restart is the #1 missing piece.**  v82 replayed MAC registers but not the PHY AN restart at the end of `mts_mac_init`.  Without AN restart, the PHY negotiates against stale parameters.
2. **Vendor MMD writes are #2, but only for robustness.**  On MT7531, Orbis's Realtek vendor writes are no-ops.  Mainline `mt7530-mdio.c` does extensive switch init, but Orbis's single-port mode (`sc->30dc == 0`) assumes the switch is already configured by boot firmware.
3. **Cable issue is #3.**  LP ability `0xc5e1` proves the partner is alive and advertising.

---

## 7. Recommended next experiment on hardware (v83)

### Must-do: add AN restart at end of MAC init

After all BAR register writes in the driver's init path, add:

```c
// Generic C22 AN restart — works on any Clause 22 PHY including MT7531
u16 bmcr;
mts_smi_read(dev, 0, &bmcr);   // reg 0 = BMCR
bmcr |= 0x1200;                 // bit 12 = AN enable, bit 9 = restart AN
mts_smi_write(dev, 0, bmcr);
```

**Expected signal:** After ~2–5 seconds, BMSR bit 5 (AN complete) should go 0→1, and then BMSR bit 2 (link status) should go 0→1. BAR+0x04 should transition from `0x00000b18` to `0x00000b19` or similar with bit 0 = 1.

### Should-do: extend kthread with AN restart on timeout

Implement the `gbe:phy_ctrl` event 0x100 handler logic in the kthread:

```c
while (!kthread_should_stop()) {
    u16 bmsr;
    mts_smi_read(dev, 1, &bmsr);  // BMSR
    if (!(bmsr & 0x0004)) {       // link down
        // Poll for up to 20s (200 × 100ms)
        int retries = 200;
        while (!(bmsr & 0x0004) && retries-- > 0) {
            msleep(100);
            mts_smi_read(dev, 1, &bmsr);
        }
        if (!(bmsr & 0x0004)) {
            // Still down — ensure 1000BASE-T advertised, then restart AN
            u16 reg9, reg4;
            mts_smi_read(dev, 9, &reg9);
            if (!(reg9 & 0x0200))
                mts_smi_write(dev, 9, reg9 | 0x0200);
            mts_smi_read(dev, 4, &reg4);
            if (!(reg4 & 0x0180))
                mts_smi_write(dev, 4, reg4 | 0x0180);
            mts_smi_read(dev, 0, &bmcr);
            mts_smi_write(dev, 0, bmcr | 0x1200);
        }
    }
    msleep(3000);
}
```

### Diagnostic: log reg 10 (1000BASE-T status)

Add a one-time log of PHY reg 10 (`MII_STAT1000`) during probe to verify the partner's 1000BASE-T advertisement:

```c
u16 stat1000;
mts_smi_read(dev, 10, &stat1000);
dev_info(&pdev->dev, "1000BASE-T status = 0x%04x\n", stat1000);
```

If bit 10 (partner 1000BASE-T full) is set, the partner supports gigabit.  If bit 11 (partner 1000BASE-T half) is set, that too.  If neither is set, the highest common mode is 100-full, and the PHY should fall back accordingly.

---

## 8. Ghidra anchors for verification

| Function | Address | What to verify |
|---|---|---|
| `mts_mac_init` | `0xffffffffc85ecb60` | AN restart at end: `mts_smi_cl22_read(param_1,0,&local_b8)` then `mts_smi_cl22_write(param_1,0,local_b8 \| 0x1200)` |
| `mts_ifup` | `0xffffffffc85ec940` | Calls `mts_mac_init` TWICE; sets gbe:ctrl event `0x10000` and gbe:phy_ctrl event `0x10100` |
| `mts_init_rings_kick` | `0xffffffffc85ef1b0` | No PHY or link-enable writes; only DMA ring + parent hash init |
| `mts_link_change` | `0xffffffffc85eeb90` | READ-ONLY on BAR+0x04; never writes it |
| `gbe:phy_ctrl` body | `0xffffffffc85f0480` | Event 0x100: C45 read `0xa2001e`; event 0x1: link-check + AN restart |
| `FUN_c85131d0` | `0xffffffffc85131d0` | Switch GPIO reset: BAR+0xf04 = 1, delay 12ms, = 2, delay 500ms |
| `msk_init_hw` | `0xffffffffc8511d50` | Full Yukon init + switch detection + GPIO reset prelude call |
