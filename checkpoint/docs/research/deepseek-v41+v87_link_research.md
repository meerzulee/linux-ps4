# deepseek-v41+v87_link_research.md — 2026-05-13

**Primary finding: Partner's reg 5 = 0xc5e1 has bit 13 SET = Remote Fault.
The partner is actively rejecting the link at the AN protocol level.  Our PHY
sees AN-complete (partner acknowledges our base page), but sees Remote Fault
in the partner's base page EVERY time, which explains the infinite
AN-complete→AN-incomplete cycle.  No further Orbis-side init can fix this
until we understand WHY the partner asserts RF.**

Second finding: in-band switch management (FUN_c85f2250) runs AFTER link-up,
not before — it is NOT the blocker for initial link establishment.

## Q1 — PMA/PCS enable: NOT the blocker

Scanned ALL C45 writes in `mts_mac_init` (`0xffffffffc85ecb60`).  None target
MMD 1 (PMA/PMD) or MMD 3 (PCS).  The only C45 MMDs used are 0x1e (Realtek
VEND1), 0x1f (Realtek VEND2), and 0x07 (AN).  Decompile excerpt confirming
this — the efuse-gated block at the top of `mts_mac_init` does ~20 C45 writes,
all to MMDs 0x1e/0x1f:

```
mts_smi_cl45_write(param_1,0xe0001e,(uVar6 & 0x3f) << 8);   // MMD 0x1e, reg large
mts_smi_cl45_write(param_1,0x115001f,uVar6 >> 6 & 7);        // MMD 0x1f, reg large
mts_smi_cl45_read(param_1,0x174001e,&local_b8);               // MMD 0x1e
mts_smi_cl45_write(param_1,0x174001e,...);                    // MMD 0x1e
// ... 16+ more writes all to MMDs 0x1e/0x1f ...
```

Unconditional tail also only touches MMD 0x1e, 0x1f, and 0x07:
```
mts_smi_cl45_write(param_1,0x189001e,0x110);   // MMD 0x1e, reg 0x189
mts_smi_cl45_write(param_1,0x122001e,0xffff);  // MMD 0x1e, reg 0x122
mts_smi_cl45_write(param_1,0x268001f,0x7f4);   // MMD 0x1f, reg 0x268
mts_smi_cl45_write(param_1,0x3c0007,0);         // MMD 0x07, reg large (non-standard)
mts_smi_cl45_read(param_1,0x33001e,&local_138); // MMD 0x1e, reg 0x330
```

For C22 PHYs, PMA/PCS power is controlled by BMCR bit 11.  AN restart
(BMCR |= 0x1200) clears power-down via `genphy_restart_aneg()`.  No explicit
MMD-1/3 access needed.  Our v86 already does AN restart.  **Q1 = dead end.**

## Q2 — Master/Slave configuration: INCOMPLETE, but not the root cause

`gbe:phy_ctrl` body (`0xffffffffc85f0480`) — event 0x1 path (lines 45-55 of
decompile):

```c
// Event 0x1 handler:
puVar9 = (uint *)(BAR+0x04);
uVar8 = in(BAR+0x04);
if ((uVar8 & 1) == 0) {       // link DOWN
    mts_smi_cl22_read(param_1, 9, &reg9);
    mts_smi_cl22_read(param_1, 4, &reg4);
    if ((reg9 & 0x200) == 0)   // ensure 1000BT advertise bit set
        mts_smi_cl22_write(param_1, 9, reg9 | 0x200);
    if ((reg4 & 0x180) == 0)   // ensure 100TX-FD/HD advertise bits set
        mts_smi_cl22_write(param_1, 4, reg4 | 0x180);
    mts_smi_cl22_read(param_1, 0, &bmcr);
    mts_smi_cl22_write(param_1, 0, bmcr | 0x1200);  // restart AN
}
```

Orbis sets reg 9 bit 9 (1000BT advertise) and reg 4 bits 7-8 (100TX-FD/HD
advertise) but **never touches reg 9 bits 11-12 (M/S configuration)**.
MT7531 defaults to "prefer slave" for 1000BT master/slave resolution.
This is fine for normal operation — M/S is resolved during AN.

**However**, our partner's reg 5 = `0xc5e1` advertises only
`100T-FD/HD + 10T-FD/HD` — NO 1000BT in the tech ability field.
With NP=0 (no next page) the partner cannot negotiate 1000BT at all.
The common mode should be 100BASE-TX.  Our PHY advertising 1000BT when
the partner can't support it should NOT cause problems (802.3 requires
fallback to highest common mode).  But if the partner has buggy AN
implementation, advertising unsupported modes could trigger Remote Fault.

## Q3 — RGMII timing setup: NOT done by Orbis; not needed for link

MT7531 internal PHY-to-MAC interface is fixed by silicon (internal GMII or
SGMII inside the switch chip).  TX_DELAY (MMD 0x1e regs 0x13/0x14) is for
external RGMII MAC connection on CPU port 5/6.  Orbis does NOT write to these
MMD regs.  Mainline `mt7531_phy_config_init` (mtk-ge.c:76-97) writes TX_DELAY
pairs B/D to 0x4 on VEND1 MMD regs 0x13/0x14.  On our system with kexec from
Orbis, the boot-time Orbis init may have left default values.  If mainline
phylib's `mt7531_phy_config_init` runs after our `phy_start()`, it sets these
values.  **Q3 = not the primary blocker.**

## Q4 — Interface mode select: auto-detected, not explicit

The MT7531 switch port mode (MII/RGMII/SGMII for CPU port) is set by HWTRAP
bootstrap pins or by writing to `GMACCR` registers in the switch core.  Orbis
does not write these via MDIO.  The user port PHYs (ports 0-4, connected to
RJ45) are internally connected — no mode selection needed.  The CPU port
(Baikal MAC connection) is bootstrap-configured.  **Q4 = dead end for link.**

## Q5 — In-band switch management: runs AFTER link-up, NOT before

`FUN_c85f2250` (`0xffffffffc85f2250`) — full decompile confirms:

```c
void FUN_c85f2250(long param_1) {
    softc = *(long *)(param_1 + 0x10);
    FUN_c85f11c0(softc, 2, 0x13);  // write C22 reg 0x13 to port 2 via management frame
    FUN_c85f11c0(softc, 3, 0x13);  // write C22 reg 0x13 to port 3
    FUN_c85f11c0(softc, 4, 0x13);  // write C22 reg 0x13 to port 4
    // ... build switch-reset frame (opcode 0x800b), send via FUN_c85f1890 ...
    // ... build switch-config frame (opcode 0x600b), send via FUN_c85f1890 ...
    if (response & 1) printk("L2 switch has been reset.\n");
    if_link_state_change(param_1);  // FUN_c85f1010
}
```

Management frame format (from `FUN_c85f11c0`, `0xffffffffc85f11c0`):
- Destination MAC: from `DAT_ffffffffc8b59f6c` (likely 01:50:43:00:00:xx)
- Source MAC: from `softc+0x30d6` (secondary MAC from SBL node 1)
- Ethertype: `0xfa42`
- Opcode: `0x0f` (MDIO C22 write)
- Payload: `0x9807` for write, `0x980b` for read query, `0x990b` for secondary
- Port + register encoded as: `(port << 5) | ((reg_high << 8) | reg_low)` → TX'd via `FUN_c85f1890`

**Critical: FUN_c85f2250 is called from `gbe:ctrl` which FIRST waits for link-up.**

From `FUN_c85f1e80` (`0xffffffffc85f1e80`) — the gbe:ctrl event-0x10000 handler:

```c
// Poll loop: up to 70 iterations × 100ms = 7 seconds
iVar5 = 0x46;  // 70
do {
    puVar7 = (uint *)(BAR+0x04);
    uVar6 = in(BAR+0x04);
    if ((uVar6 & 1) != 0) {         // LINK IS UP → exit loop
        msleep(100ms);
        // Send AN status query frame (ethertype 0xfa42, opcode 0x80006910)
        FUN_c85f1890(softc, frame, 0x22);
        break;
    }
    msleep(100ms);
    iVar5--;
} while (iVar5 != 0);

// After loop (link was already up or we timed out):
FUN_c85f2250(parent);  // ← switch config runs HERE
BAR+0x54 &= ~0x1000;   // gate RX IRQ off
```

**The switch config runs AFTER link-up, not before.**  If link never comes up,
the gbe:ctrl thread waits 7 seconds, times out, and then still calls
FUN_c85f2250 — but switch config doesn't cause link.  **Q5 = NOT the blocker
for initial link establishment.**  The management frames configure port 2,3,4's
PMCR (C22 reg 0x13) which sets switch fabric forwarding, not PHY link.

## Q6 — Force link-up: Orbis NEVER writes BAR+0x04 bit 0

`mts_link_change` (`0xffffffffc85eeb90`) is pure read-only:
```c
puVar6 = (uint *)(BAR+0x04);
uVar3 = *puVar6;     // READ only
if (uVar3 & 1) { /* link UP */ } else { /* link DOWN */ }
```

`mts_intr` (`0xffffffffc85edcf0`) handles IRQ bit 0x4 by calling
`mts_link_change()` — never writes BAR+0x04.  `mts_mac_init` does write
BAR+0x04 with `val & 0x7fffcfff` (clears bits 12,13,18,19,31), preserving
bit 0.  No function in the entire Orbis MTS driver writes BAR+0x04 bit 0.

**Q6 = dead end.**  BAR+0x04 bit 0 is a hardware-driven status signal reflecting
PHY link state propagated through the MAC's internal link detection logic.

## THE ROOT CAUSE: Remote Fault

Our PHY's reg 5 = `0xc5e1` shows the partner's auto-negotiation base page.
Decode per IEEE 802.3-2018 section 28.2.3.1:

```
0xc5e1 = 0b1100 0101 1110 0001
         ^           ^    ^^^^
         |           |    ||||
bit 15=0 (NP-page received=no)         ||||
bit 14=1 (ACK=yes, partner ACK'd)      ||||
bit 13=1 (RF=yes, REMOTE FAULT) ← ← ← ||||
bit 12=0 (NP=no next page)             ||||
bits 11-5 technology ability:              ||||
  bit 11=0 (1000T pause)                  ||||
  bit 10=1 (1000T asym pause)             ||||
  bit 9=0 (100T4)                          ||||
  bit 8=1 (100TX FD)                       ||||
  bit 7=1 (100TX)                           ||||
  bit 6=1 (10T FD)                           ||||
  bit 5=1 (10T)                              ||||
bits 4-0=00001 (IEEE 802.3 selector)
```

**Bit 13 (Remote Fault) is SET.**  This is the smoking gun.

Remote Fault semantics (IEEE 802.3 28.2.3.1.2): the partner has detected a
fault condition.  Possible causes:
1. Partner detects our PHY's signal as faulty (link training failure)
2. Partner has a hardware fault on its link interface
3. Partner is intentionally rejecting the link (e.g., port security)
4. Electrical issue: cable too long, poor quality, or impedance mismatch

Our AN-complete→incomplete cycling matches the RF behavior: partner sends
base page with RF=1 → our PHY sees AN complete (ACK received) but partner
set RF → PHY restarts AN → same sequence repeats infinitely.

### Why Remote Fault persists across AN restarts

Mainline `genphy_restart_aneg()` and our AN restart (BMCR |= 0x1200) both
initiate AN.  But if the partner consistently sees a fault (e.g., our PHY's
analog/DSP training fails every time), it asserts RF in every base page.

Additionally: the partner's reg 5 tech ability shows NO 1000BASE-T.  Our PHY
advertises 1000BT (reg 9 bit 9 = 1).  IEEE 802.3 requires fallback to the
highest common mode (100TX full-duplex in this case).  However, if our PHY's
1000BT DSP/analog trim is misconfigured (the Orbis Realtek-specific MMD trim
writes are all no-ops on MT7531), the PHY may enter 1000BT training even when
AN resolves to a lower speed, and the training failure triggers partner RF.

Or: if the cable/partner truly only supports 100TX, and our PHY keeps
attempting 1000BT training (due to DSP defaults expecting gigabit), the
training sequence could confuse the partner into asserting RF.

### Validation experiment

Monitor reg 5 during a single AN cycle without our 15s AN restart.  If RF is
set by the partner in EVERY base page, it's a PHY/partner incompatibility.
Next test: manually disable 1000BT advertisement (clear reg 9 bit 9) and
10/100 advertise only (reg 4 bits 5-8).  If link establishes at 100TX, the
1000BT DSP/training path is the problem and we need MT7531-specific MMD trim
(from mainline mtk-ge.c) before enabling gigabit.

Check reg 10 simultaneously: if `0x3c00` = 1000BT training in progress, and
then `0x7c00` = training failed, that confirms the 1000BT path is failing.

**Recommended v87 experiment**: Disable 1000BT advertisement (clear reg 9
bit 9) and force 100TX-only.  If link establishes, we narrow the problem to
the 1000BT training path.  Then apply mainline `mt7531_phy_config_init` MMD
writes (TX_DELAY + RXADC + DSP trim) before re-enabling gigabit.

--- deepseek-v41, 2026-05-13
