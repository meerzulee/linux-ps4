# PS4 Baikal GBE v87 — link bring-up gap analysis (Q1–Q6)
**Agent:** kimi-k2.6 (OpenCode)  
**Date:** 2026-05-13  
**Ghidra program:** `orbis-12.02.elf` (project `orbis-ps4-dump`)

---

## Lead finding: Orbis does *nothing* post-mts_mac_init that forces link — the gap is almost certainly inside mts_mac_init's efuse-gated C45 block

Every function that runs after `mts_mac_init` (including `mts_ifup`, `mts_init_rings_kick`, gbe:ctrl, gbe:phy_ctrl, `mts_intr`) only **reacts** to link state or **maintains** it.  None of them write a "link enable" bit, PMA power-up, or interface-mode switch.  The PHY either brings link up from the state `mts_mac_init` leaves it in, or it never does.  The efuse-gated block contains ~20 C45 read-modify-writes to MMD 0x1e registers that the Linux driver skips because the efuse check is gated on Sony efuse[0x6c] — but those registers may overlap with MT7531 vendor analog calibration.

---

## Q1 — PMA / PCS enable (MMD 1 or MMD 3)

**Result: ZERO C45 accesses to MMD 1 or MMD 3 anywhere in the MTS driver.**

I searched `mts_mac_init` (`FUN_ffffffffc85ecb60`, 0xc85ecb60–0xc85edc99) and `mts_ifup` (`FUN_ffffffffc85ec940`, 0xc85ec940–0xc85ecac3) exhaustively.  Every C45 access uses the `mts_smi_cl45_read` / `mts_smi_cl45_write` helpers.  The MMD device addresses encoded in the call arguments are:

| C45 address | MMD | Register | Context |
|---|---|---|---|
| `0xe0001e` | 0x1e | 0xe0 | efuse trim (gated) |
| `0x115001f` | 0x1f | 0x115 | efuse trim (gated) |
| `0x174001e`–`0x220001e` | 0x1e | 0x174–0x220 | efuse trim (gated) |
| `0x96001e` | 0x1e | 0x96 | efuse trim (gated) |
| `0x37001e` | 0x1e | 0x37 | efuse trim (gated) |
| `0x39001e` | 0x1e | 0x39 | efuse trim (gated) |
| `0x107001f` | 0x1f | 0x107 | efuse trim (gated) |
| `0x171001e` | 0x1e | 0x171 | efuse trim (gated) |
| `0x189001e` | 0x1e | 0x189 | **unconditional tail** |
| `0x122001e` | 0x1e | 0x122 | **unconditional tail** |
| `0x268001f` | 0x1f | 0x268 | **unconditional tail** |
| `0x3c0007` | 0x07 | 0x3c | **unconditional tail** |
| `0x33001e` | 0x1e | 0x330 | **unconditional tail** |

There are **no calls with MMD = 1 (PMA/PMD) or MMD = 3 (PCS)**.  Orbis relies entirely on the PHY's default PMA/PCS state after reset.  On a standard MT7531, the PMA comes out of reset enabled (bit 11 of PMA control = 0, i.e. not powered down).  **If your driver is not explicitly powering down the PMA, this is not the blocker.**

---

## Q2 — Master/Slave configuration (reg 9 bits 11–12)

**Result: Orbis never touches bits 11–12 of reg 9.**

The only writes to PHY reg 9 in the entire decompiled MTS driver are in `gbe:phy_ctrl` (`FUN_ffffffffc85f0480`, 0xc85f0480–0xc85f090f):

```c
// Event 0x100 path (AN poll), line ~0x86c in source:
if ((uVar11 & 0x100) != 0) {
    ...
    if ((local_3a & 0x200) == 0) {
        mts_smi_cl22_write(param_1, 9, local_3a | 0x200);  // sets bit 9 ONLY
    }
    ...
}

// Event 0x1 path (link-down recovery), line ~0x895:
if ((uVar11 & 1) != 0) {
    ...
    if ((local_40 & 0x200) == 0) {
        mts_smi_cl22_write(param_1, 9, local_40 | 0x200);  // sets bit 9 ONLY
    }
    ...
}
```

Both paths do `reg9 |= 0x0200` (bit 9 = 1000BASE-T full-duplex advertise).  **Neither path sets bits 11–12** (M/S config: `00` = prefer master, `01` = prefer slave, `10` = manual master, `11` = manual slave).

The reg 9 value observed in v82 is `0x0200`.  That means M/S = `00` = **prefer master**, which is the PHY default.  On MT7531, the default M/S resolution should work with most partners.  **M/S configuration is not the blocker.**

---

## Q3 — RGMII / SGMII timing setup

**Result: No explicit TX_DELAY / RX_DELAY C45 writes.  But the parent prelude configures BAR+0x11c, which is the MAC-side interface-mode register.**

### C45 vendor MMDs (other than 0x1e/0x1f)

The only non-0x1e/0x1f C45 access in all of MTS is `0x3c0007 = 0` (MMD 7, reg 0x3c).  There is **no C45 access to any register that mainline `mtk-ge.c` uses for delay** (MMD 0x1e regs 0x13, 0x14).  Orbis's MMD 0x1e writes target registers 0x37, 0x39, 0x96, 0x120–0x220, 0x330 — none of which overlap with mtk-ge.c's delay registers.

### MAC-side interface configuration

The parent prelude `FUN_ffffffffc85131d0` (0xc85131d0) writes:

```c
if (param_2 == 1) {  // normal init
    BAR+0xf10 = 1;  udelay(immediate);  BAR+0xf10 = 2;
    BAR+0xf04 = 1;  udelay(12000);      BAR+0xf04 = 2;  udelay(500000);
    // ... clock config ...
    BAR+0x120 = 1;
    BAR+0x11c &= 0xf8ff;   // clears bits 8–10
}
if (param_2 == 0) {  // reset path
    BAR+0x11c = 0x700;     // sets bits 8–10
}
```

**BAR+0x11c bits 8–10 are the MAC-PHY interface mode select.**  The reset path sets them to `0x7` (bits 8+9+10 = `111`).  The normal init path clears them to `0x0` (`000`).

The v82 doc confirms v82 does `BAR+0x11c &= 0xf8ff`.  This selects mode `000`.  On the Baikal MAC, the modes are likely:
- `000` = RGMII (the expected mode for MT7531)
- `001` = MII
- `010` = RMII
- `011` = SGMII
- `111` = reset/test mode

If v82 cleared bits 8–10, the MAC is in RGMII mode.  **This is correct and not the blocker.**

However, RGMII requires **TX and RX delay** on either the MAC or PHY side.  Mainline `mtk-ge.c` sets TX delay = 0x4 and RX delay = 0x4 on the PHY (MMD 0x1e regs 0x13/0x14).  Orbis does **not** set these.  On MT7531, the default delay might be 0 (no delay).  If the Baikal MAC also has no internal delay, the RGMII timing would be violated.

**Hypothesis:** The PS4 PCB has a fixed RGMII trace length that requires delay.  MediaTek may have programmed the MT7531's internal EEPROM/fuses to have non-zero default delay for the PS4 SKU.  If so, Orbis does not need to set it.  But if the Linux driver resets the PHY (via `0x3c0007 = 0` or BMCR reset) and loses the factory delay setting, link won't train.

**Experiment:** Read MMD 0x1e reg 0x13 and 0x14 from the running PS4 (via the driver's SMI accessor) BEFORE the driver initializes anything.  If they are non-zero (e.g., `0x04`), the factory delay is present.  If they are `0x00`, delay is missing and you need to replicate `mtk-ge.c`'s writes.

---

## Q4 — Pseudo MII / interface mode select

**Result: No explicit vendor "mode select" register.  Interface is hard-configured via BAR+0x11c.**

There is no C22 or C45 write that looks like an interface-mode switch (e.g., no write to a vendor register with documented mode bits like `RGMII_EN`, `SGMII_SEL`, etc.).  The Baikal MAC's interface mode is configured purely via BAR+0x11c bits 8–10, set in `FUN_c85131d0`.

The MT7531 PHY itself does not need to be told the interface mode — it auto-detects RGMII vs SGMII based on the reference clock and signal presence.  **Interface mode selection is not the blocker.**

---

## Q5 — In-band switch management (FUN_c85f11c0 / FUN_c85f2250)

**Result: In-band management is a RECOVERY path, not a bring-up prerequisite.**

### When is FUN_c85f2250 called?

`FUN_c85f2250` (0xc85f2250–0xc85f2497) calls `FUN_c85f11c0` to send MDIO management frames via the TX engine.  It is called from exactly **one** place: `FUN_ffffffffc85f1e80` (`gbe:ctrl` init helper, 0xc85f1e80).

In `FUN_c85f1e80`:

```c
if (*(int *)(param_1 + 0x30e0) == 0) {
    // carrier polling ENABLED — normal path
    mts_link_change(param_1);
    return;
}
// carrier polling DISABLED — unusual path
for (i = 0x46; i > 0; i--) {
    if (readl(BAR+0x04) & 1) {
        // link came up — send TX frame, break
        ...
        break;
    }
    msleep(100);
}
FUN_ffffffffc85f2250(plVar2);   // only here
```

So `FUN_c85f2250` runs **only** when `softc+0x30e0 != 0` (carrier polling disabled).  On a normal Orbis boot, `softc+0x30e0` is likely `0` (polling enabled), and `FUN_c85f2250` **never runs during bring-up**.

### What does FUN_c85f2250 actually do?

```c
void FUN_c85f2250(long param_1) {
    lVar2 = *(long *)(param_1 + 0x10);   // ifnet pointer
    FUN_c85f11c0(lVar2, 2, 0x13);       // send MDIO mgmt frame to switch port 2, reg 0x13
    FUN_c85f11c0(lVar2, 3, 0x13);       // send to switch port 3, reg 0x13
    FUN_c85f11c0(lVar2, 4, 0x13);       // send to switch port 4, reg 0x13
    // construct ethertype 0xFA42 frame, opcode 0x800B -> "switch reset"
    FUN_c85f1890(lVar2, frame, 0x20);
    // construct ethertype 0xFA42 frame, opcode 0x600B -> "switch probe"
    iVar3 = FUN_c85f1890(lVar2, frame, 0x20);
    if ((iVar3 == 0) && ((local_59 & 1) != 0)) {
        dev_printf("L2 switch has been reset.\n");
    }
    FUN_c85f1010(param_1);   // update link state
}
```

This is a **switch fabric reset** that re-programs the MT7531's internal VLAN/forwarding table.  It is triggered only when the link goes down and needs recovery.

**Conclusion: In-band switch management is NOT required for initial link bring-up.**  It is only needed if the switch gets into a bad state after link down.  Skipping it for v87 is safe.

---

## Q6 — Any other "force link up" mechanisms

### BAR+0x04 is NEVER written to set bit 0

I searched every function in the MTS driver for writes to `BAR+0x04`:

| Function | Operation on BAR+0x04 |
|---|---|
| `mts_mac_init` (0xc85ecb60) | Read-modify-write: `val &= 0x7FFFCFFF` (clears bits 8–9, 12–13).  Never sets bit 0. |
| `mts_link_change` (0xc85eeb90) | **Read-only.** Decodes speed/duplex/flow. |
| `mts_intr` (0xc85edcf0) | **Read-only** (inside link-change handler at bit 0x4). |
| `gbe:phy_ctrl` (0xc85f0480) | **Read-only** (event 0x1 handler). |

**Linkreg bit 0 is purely a hardware status register.**  No software path forces it high.

### mts_intr first-call side effect

`mts_intr` (`FUN_ffffffffc85edcf0`) has a first-call init block:

```c
if (*(int *)(param_1 + 0x309c) == 0) {
    *(int *)(param_1 + 0x309c) = 1;   // MAC_ENABLE flag
    writel(0x10001388, BAR+0x204);    // IRQ block enable
    writel(0x7bfffe,    BAR+0x54);    // per-IRQ mask
}
```

This is the standard IRQ enable sequence.  It does not touch the PHY or link.  **Not the blocker.**

### Carrier / link_up functions

No function named `*link_up*` or `*carrier*` exists in the MTS driver beyond `mts_link_change`.  The carrier state is updated via FreeBSD's `if_link_state_change` (`FUN_ffffffffc85f1010`), which is called only from `FUN_c85f2250` (switch reset path) and from `mts_link_change` when link is already up.

---

## The real gap: efuse-gated C45 block + unconditional tail C45 writes

### Why the efuse block matters

`mts_mac_init` gates the bulk of its C45 writes on:

```c
uVar6 = FUN_ffffffffc8764760(0x6c);   // read Sony efuse at offset 0x6c
if ((uVar6 & 0x80800000) == 0x80800000) {
    // ~20 C45 read-modify-writes to MMD 0x1e/0x1f
}
```

The Linux driver does not have `FUN_c8764760`.  Most implementations **skip the entire block** because they can't read the Sony efuse.  But on the actual PS4 hardware, this check **might pass** (efuse was programmed for the Realtek PHY on the same PCB).  Even if the efuse values are for Realtek, the **register addresses** on MMD 0x1e might control analogous analog parameters on MT7531.

### What is in the efuse block?

Key writes (all to MMD 0x1e unless noted):

| C45 addr | Operation | Likely function on Realtek |
|---|---|---|
| `0x174001e` | Read-modify, set byte from lookup table | TX amplitude / impedance |
| `0x175001e` | Read-modify, set byte from lookup table | RX sensitivity |
| `0x172001e` | Read-modify, set bits from efuse[0x5c]/[0x60] | DSP coefficient |
| `0x173001e` | Read-modify, set bits from efuse[0x5c]/[0x64] | DSP coefficient |
| `0x120001e` | Write calculated | Impedance trim |
| `0x160001e` | Write calculated | Impedance trim |
| `0x170001e` | Write calculated | TX amplitude |
| `0x180001e` | Write calculated | TX amplitude |
| `0x190001e` | Write calculated | TX amplitude |
| `0x200001e` | Write calculated | TX amplitude |
| `0x210001e` | Write calculated | TX amplitude |
| `0x220001e` | Write calculated | TX amplitude |
| `0x96001e` | Write 0x8000 | Power / clock gate |
| `0x37001e` | Write 0x33 | Vendor calibration |
| `0x39001e` | R/M/W: clear bit 0x4800, set 0x2000, clear 0x2000 | Test/loopback toggle |
| `0x107001f` | R/M/W: clear bit 0x1000 | Vendor control (MMD 0x1f) |
| `0x171001e` | R/M/W: set 0x180, then clear 0x180 | Power-sequence toggle |

### The unconditional tail (runs even if efuse check fails)

```c
mts_smi_cl45_write(param_1, 0x189001e, 0x110);     // MMD 0x1e reg 0x189 = 0x110
// ... Realtek extended-page C22 pokes ...
mts_smi_cl45_write(param_1, 0x122001e, 0xffff);    // MMD 0x1e reg 0x122 = 0xffff
// ... more Realtek C22 pokes ...
mts_smi_cl45_write(param_1, 0x268001f, 0x7f4);     // MMD 0x1f reg 0x268 = 0x7f4
mts_smi_cl22_read(param_1, 4, &local_b8);
mts_smi_cl22_write(param_1, 4, local_b8 & 0xf3ff);  // clear ANAR bits 10–13
// BAR+0x04 = saved & 0x7fffcfff
// BAR+0x078 bit 0 clear
mts_smi_cl45_write(param_1, 0x3c0007, 0);          // MMD 7 reg 0x3c = 0
mts_smi_cl45_read(param_1, 0x33001e, &local_138);
mts_smi_cl45_write(param_1, 0x33001e, local_138 & 0xefff);  // clear bit 12
// BMCR |= 0x1200
```

**Does your v86 driver replay the unconditional tail C45 writes (0x189, 0x122, 0x268, 0x3c0007, 0x330)?**  The v82 doc explicitly says "It did not replay the full PHY/SMI sequence at the end of the function."  If v86 still skips these, you are missing:

1. `0x189001e = 0x110` — on Realtek, this is a vendor-specific calibration register. On MT7531 MMD 0x1e, register 0x189 might control TX/RX analog parameters.
2. `0x122001e = 0xffff` — on Realtek, this might be a power/clock gate. On MT7531, it might enable PHY sub-blocks.
3. `0x268001f = 0x7f4` — on Realtek MMD 0x1f, this is a vendor register. On MT7531, MMD 0x1f is VEND2; reg 0x268 might be a port-control or power-control register.
4. `0x3c0007 = 0` — MMD 7 vendor reg. On MT7531, this might be a PHY enable or AN start trigger.
5. `0x33001e &= ~0x1000` — clear bit 12 on MMD 0x1e reg 0x330. On MT7531, this might disable a power-saving or test mode.

**These five C45 writes are in the unconditional tail — they run on every Orbis boot.**  If the Linux driver skips them because they look "Realtek-specific," link may not come up.

---

## Recommended next experiment on hardware (v87)

### Test A — replay the unconditional tail C45 writes verbatim

After all BAR register writes in your init path, add these five C45 operations (they are harmless if the registers don't exist on MT7531):

```c
// From mts_mac_init unconditional tail, in order:
smi_c45_write(dev, 0x189001e, 0x110);
// ... Realtek C22 extended-page pokes (optional, may be no-ops on MT7531) ...
smi_c45_write(dev, 0x122001e, 0xffff);
// ... more C22 pokes ...
smi_c45_write(dev, 0x268001f, 0x7f4);

// Read ANAR, clear bits 10–13
val = smi_c22_read(dev, 4);
smi_c22_write(dev, 4, val & 0xf3ff);

// BAR+0x04 = read & 0x7fffcfff
// BAR+0x078 &= ~1

// Critical tail C45:
smi_c45_write(dev, 0x3c0007, 0);
val = smi_c45_read(dev, 0x33001e);
smi_c45_write(dev, 0x33001e, val & 0xefff);

// AN restart
val = smi_c22_read(dev, 0);
smi_c22_write(dev, 0, val | 0x1200);
```

**Expected signal:** After adding the tail C45 writes, watch BMSR for ~10 seconds. If bit 2 transitions from 0->1, one of these writes was the missing piece.

### Test B — read MT7531 delay registers before init

Before your driver touches anything, read these from the raw SMI:

```c
u16 txd = smi_c45_read(dev, 0x1e0013);  // MMD 0x1e reg 0x13
u16 rxd = smi_c45_read(dev, 0x1e0014);  // MMD 0x1e reg 0x14
dev_info("MT7531 delay: TX=0x%04x RX=0x%04x\n", txd, rxd);
```

If both are `0x0000`, the default delay is missing and you need to add mainline's `mtk-ge.c` writes:

```c
smi_c45_write(dev, 0x1e0013, 0x04);  // TX delay
smi_c45_write(dev, 0x1e0014, 0x04);  // RX delay
```

### Test C — check whether efuse block would have run

Read Sony efuse offset 0x6c (if possible via the PS4's efuse sysfs or via `dd` of `/dev/mem`).  If bits 31 and 23 are both set, the efuse block WOULD run on Orbis.  In that case, the ~20 C45 writes in the efuse block are part of the real bring-up and should be replicated (even though the values are Sony-specific, the register addresses might hit MT7531 analog controls).

If you cannot read the efuse, **unconditionally replay the efuse block's C45 writes with default values** (use the constants from the Orbis decompile, substituting 0x7f from the lookup table `DAT_ffffffffc8b59a80` for any efuse-derived index):

```c
// Simplified efuse block (always run, ignore efuse check):
smi_c45_write(dev, 0x174001e, 0x807f);  // table[0x3f] = 0x7f, OR 0x8000
smi_c45_write(dev, 0x175001e, 0x807f);
smi_c45_write(dev, 0x172001e, 0x3f00);  // efuse defaults
smi_c45_write(dev, 0x173001e, 0x3f00);
// ... etc, using the constant values from the decompile ...
```

### Test D — stop AN restart cycling

Your kthread restarts AN every 15s.  Orbis waits **200 iterations x 100ms = 20 seconds** before restarting.  The 15s cadence might be interrupting link training.  Change the kthread to:

```c
if (link_down) {
    // Wait 20s before restarting AN, matching Orbis
    for (i = 0; i < 200 && link_still_down; i++)
        msleep(100);
    if (link_still_down) {
        // read reg 9/4, ensure advertise bits, THEN restart AN
        smi_c22_write(dev, 0, bmcr | 0x1200);
    }
}
```

**If link comes up after extending the timeout from 15s to 20s, the issue was AN restart frequency.**

---

## Dead end honestly stated

I cannot confirm from Ghidra alone whether the efuse block's C45 writes are **required** for MT7531 or are Realtek-only no-ops.  The decompile shows the block is gated on Sony efuse[0x6c], which we cannot read from Linux without the efuse driver.  If the efuse check **fails** on the PS4 (because the unit has MT7531, not Realtek), Orbis skips the efuse block on the real hardware too, and the link bring-up is purely from the unconditional tail + defaults.  If the efuse check **passes**, the block's C45 writes are part of the real init and the Linux driver must replicate them.

**The only way to know is hardware experiment:** run Test A (unconditional tail C45 writes) and Test C (efuse block with defaults).  One of them will almost certainly produce a BMSR bit 2 transition.

---

## Ghidra anchors for verification

| Function | Address | What to verify |
|---|---|---|
| `mts_mac_init` | `0xffffffffc85ecb60` | efuse gate at line ~0xc85ecc83; unconditional tail starts after `}` |
| `mts_smi_cl45_write` | search for C45 | All MMD addresses in call args |
| `mts_ifup` | `0xffffffffc85ec940` | No SMI/BAR writes beyond `mts_mac_init` call |
| `gbe:phy_ctrl` | `0xffffffffc85f0480` | Event 0x100: only reg 9 bit 9 set; event 0x1: same |
| `gbe:ctrl init` | `0xffffffffc85f1e80` | Only calls `FUN_c85f2250` when `softc+0x30e0 != 0` |
| `FUN_c85f2250` | `0xffffffffc85f2250` | Recovery-only; sends ethertype 0xFA42 frames |
| `mts_intr` | `0xffffffffc85edcf0` | First-call IRQ enable; link-change handler is read-only on BAR+0x04 |
| `mts_link_change` | `0xffffffffc85eeb90` | Read-only on BAR+0x04 |
| `FUN_c85131d0` | `0xffffffffc85131d0` | BAR+0x11c &= 0xf8ff (mode select) |
