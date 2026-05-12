# Link bring-up deep-dive — glm-5.1, 2026-05-12 (v83 session)

## Lead finding: Orbis sends an MDIO switch-management frame to the MT7531 *before* link can come up

`mts_mac_init` ends with a C45 write to MMD device 7 register 0 (`SMI_CL45_write(sc, 0x3c0007, 0)`)
that targets MT7531's integrated switch management port (MMD dev 7 = MDIO manage-
ment, reg 0 = SW_RESET).  The gbe:ctrl init thread (`FUN_c85f1e80`) then calls
`FUN_c85f2250` which sends a **second** switch-reset command (ethertype 0x8906
followed by 0x600B) via a hardware TX frame engine at `BAR+0x1C`.  After that
the gbe:ctrl thread **clears bit 12 of BAR+0x54** (disabling the RX-ready IRQ)
and, on carrier-polling-enabled devices, the gbe:phy_ctrl thread begins a
3-second BMSR-polling loop.

In Linux, none of these steps happen.  The standalone ps4_mts driver must
replicate: (1) the C45 switch-reset write, (2) the TX-based switch probe,
and (3) at minimum a periodic SMI status read.  Without the switch being
explicitly told to forward traffic to the host port, link can be
electrically up on the PHY but never reach `BAR+0x04 bit 0`.

---

## 1. Complete mts_mac_init register-write sequence (reconciliation)

Decompiled `mts_mac_init` (FUN_c85ecb60).  Every register write, in order:

| Step | BAR offset | Operation | Value / Notes |
|------|-----------|-----------|---------------|
| 1 | 0x200 | write 0 | Master reset clear |
| 2 | 0x050 | W1C (read, then write back = read value) | Ack any pending IRQs |
| 3 | — | pcie_get_mrrs(); if 0x200 → Set to 0x800 | PCIe MPS tuning |
| 4 | — | udelay(680) | Wait for MAC reset |
| 5 | — | SMI_CL22_read(phy, reg2) & SMI_CL22_read(phy, reg3) | PHY ID reads (discarded) |
| 6 | 0x0ac | write 9 | Unknown |
| **7–23** | — | **efuse conditional block** (if `efuse(0x6c) & 0x80800000 == 0x80800000`) | See below |
| 7 | — | C45_write(MMD 0x1e, reg 0xe000, `efuse(0x68) & 0x3f << 8`) | efuse trim |
| 8 | — | C45_write(MMD 0x1f, reg 0x115, `efuse(0x68) >> 6 & 7`) | efuse trim |
| 9 | — | C45_read/modify MMD 0x1e reg 0x174 | Fill upper byte from table[efuse(0x60)] |
| 10 | — | C45_read/modify MMD 0x1e reg 0x174 | Fill lower byte from same table |
| 11 | — | C45_read/modify MMD 0x1e reg 0x175 | Same for reg 0x175 |
| 12 | — | C45_read/modify MMD 0x1e reg 0x175 | Second byte |
| 13 | — | C45_read/modify MMD 0x1e reg 0x172 | `efuse(0x5c) >> 4 & 0x3f00` + preserve |
| 14 | — | C45_read/modify MMD 0x1e reg 0x172 | `efuse(0x60) >> 7 & 0x3f` |
| 15 | — | C45_read/modify MMD 0x1e reg 0x173 | `efuse(0x5c) >> 2 & 0x3f00` + preserve |
| 16 | — | C45_read/modify MMD 0x1e reg 0x173 | `efuse(0x60) >> 5 & 0x3f` (also efuse(0x64)) |
| 17 | — | C45_write(MMD 0x1e, reg 0x120, `efuse(0x5c) >> 0x1a * 0x401`) | Impedance trim |
| 18 | — | C45_write(MMD 0x1e, reg 0x160, calculated) | Impedance trim |
| 19 | — | C45_write(MMD 0x1e, reg 0x170, `efuse(0x60) >> 0xd & 0x3f * 0x101`) | TX amplitude |
| 20 | — | C45_write(MMD 0x1e, reg 0x180, calculated) | TX amplitude |
| 21 | — | C45_write(MMD 0x1e, reg 0x190, `efuse(0x64) & 0x3f * 0x101`) | More trim |
| 22 | — | C45_write(MMD 0x1e, reg 0x200, calculated) | More trim |
| 23 | — | C45_write(MMD 0x1e, reg 0x210, `efuse(0x64) >> 0x13 & 0x3f` * 0x101) | More trim |
| 24 | — | C45_write(MMD 0x1e, reg 0x220, calculated) | More trim |
| 25 | — | C45_write(MMD 0x1e, reg 0x096, 0x8000) |_extended-page specific calibration_ |
| 26 | — | C45_write(MMD 0x1e, reg 0x037, 0x33) | _extended-page calibration_ |
| 27 | — | C45_read/modify MMD 0x1e reg 0x039 | Clear bit 0x4800 (disable something) |
| 28 | — | C45_read/modify MMD 0x1f reg 0x107 | Clear bit 0x1000 |
| 29 | — | C45_read/modify MMD 0x1e reg 0x171 | Set bits 0x180 |
| 30 | — | C45_read/modify MMD 0x1e reg 0x039 | Set bit 0x2000 |
| 31 | — | C45_read/modify MMD 0x1e reg 0x039 | Clear bit 0x2000 |
| 32 | — | udelay(50) | |
| 33 | — | C45_read/modify MMD 0x1e reg 0x171 | Clear bits 0x180 |
| **34** | **BAR+0x004** | **R/M/W: read, clear bits 0x300 and 0x7000** | ~ `val & 0x7FFFCFFF` — clears speed bits? |
| 35 | — | C45_write(MMD 0x1e, reg 0x189, 0x110) | |
| 36 | — | C22 write(0x1f, 0x52b5) then {0x11, 0x12, 0x10} | Realtek extended-page calibration block 1 |
| 37 | — | C22 write(0x1f, 0x52b5) then {0x11, 0x12, 0x10} | Block 2 |
| 38 | — | C22 write(0x1f, 3); write(0x1c, 0xc92); write(0x1f, 0) | Realtek page 3 calibration |
| 39 | BAR+0x07c | write 25000000 | MAC clock reference = 25 MHz |
| 40 | — | C45_write(MMD 0x1e, reg 0x122, 0xFFFF) | |
| 41 | — | C22 write(0x1f, 0x52b5) then {0x11, 0x12, 0x10} | Block 3 |
| 42 | — | C22 write(0x1f, 0x52b5) then {0x11, 0x12, 0x10} | Block 4 |
| 43 | — | C45_write(MMD 0x1f, reg 0x268, 0x7f4) | **MT7531 MMD reg** |
| 44 | — | C22 write(0x1f, 0x52b5) then {0x11, 0x12, 0x10} | Block 5 |
| 45 | — | C22 write(0x1f, 0x52b5) then {0x11, 0x12, 0x10} | Block 6 |
| 46 | — | C22 read(4); write(4, val & 0xF3FF) | Clear bits 10-13 in ANAR |
| **47** | **BAR+0x004** | **R/M/W again: `val & 0x7FFFCFFF`** | Same as step 34 — re-clear speed bits |
| 48 | BAR+0x078 | R/M/W: clear bit 0 | Enable RX (open gate) |
| 49 | — | C45_write(MMD 7, reg 0, value 0) | **SW_RESET to MT7531 switch chip** |
| 50 | — | C45_read(MMD 0x1e, reg 0x330); write(0x330, val & 0xEFFF) | Clear bit 0x1000 |
| 51 | — | C22 read(0); write(0, val | 0x1200) | BMCR: set AN enable + restart AN |
| 52 | BAR+0x014 | write MAC addr bytes 0-3 byte-swapped | MAC address low |
| 53 | BAR+0x018 | write MAC addr bytes 4-5 byte-swapped | MAC address high |
| 54 | BAR+0x140 | write secondary MAC (if enabled, with bit 31 set) | Secondary MAC |
| 55 | BAR+0x144 | write secondary MAC bytes 4-5 | |
| 56 | BAR+0x00c | R/M/W: clear bit 7 | MAC_CTRL2: clear unknown bit |
| 57 | BAR+0x074 | write 0x2277 | MAC_PAUSE |
| 58 | BAR+0x008 | R/M/W: OR 0x07597C00 | MAC_CTRL: set all MAC feature bits |
| 59 | BAR+0x1d4 | write 1 | Unknown |
| 60 | BAR+0x010 | R/M/W: `val & 0xFFFFFF6E | 0x81` | MAC_CTRL3: clear bits 1,4,5,8,8; set bits 0,7 |
| 61 | BAR+0x030 | write 0x10100 | MAC_MODE |
| 62–75 | 0x1bc..0x1d0 | multicast hash filter setup | (conditional, when gbe_port_enable != 0) |
| 76 | BAR+0x1c8 | R/M/W: OR `0xC0000000 | (count * 0x100 | count)` | MCAST_HASH_MASK with promisc bits |
| 77 | BAR+0x1c4 | write 3 | End multicast filter load |

### Key observations from the complete sequence

**Step 34 + 47**: `BAR+0x004` is read-modified-written **twice** with `val & 0x7FFFCFFF`.
Bits 12-13 (0x3000) and bits 8-9 (0x300) are cleared.  Per the link_status register
definition, bits 2-3 are speed (00=10M, 01=100M, 10=1000M).  Bits 8-9 are unknown.
This clears speed to 10M and resets the upper speed/auto bits — a deliberate
forced-downspeed before PHY init.

**Step 49**: `C45_write(MMD 7, reg 0, 0)` — this is **MT7531 switch SW_RESET**.
MMD device address 7 with register 0 is the switch management register block.
Writing 0 issues a reset.  This is the critical step that the Linux driver
**never does**, and it explains why link never comes up: the switch chip may
need an explicit reset over MDIO before its port-forwarding rules are programmed.

**Step 50**: C45_read/modify MMD 0x1e reg 0x330, clear bit 0x1000.  MMD 0x1e
is the Realtek PHY vendor MMD.  Register 0x330 bit 12 being cleared is likely
a "force TX/power" or "disable EEE" control.

**Step 43**: `C45_write(MMD 0x1f, reg 0x268, 0x7f4)` — this targets
MMD device 0x1f (another Realtek extended page).  Register 0x268 on MT7531
switches is likely a port-mirroring or VLAN-related configuration register.

---

## 2. mts_ifup (FUN_c85ec940) — complete

Already decompiled in prior session. Key additions:

```c
void mts_ifup(void) {
    softc = curthread->td_softc;  // via FUN_c8602ac0
    mtx_lock(softc + 0x30b0, "if_mts.c:0x12e4");
    softc[0x32b0] = 0xA000000000000;  // marks interface as "up"
    mts_mac_init(softc);              // ← full register sequence above
    
    // Clear bit 6 of BAR+0x1c8 (MCAST_HASH_DONE):
    *BAR(BAR+0x1c8) &= ~0x40;
    
    mts_init_rings_kick(softc);       // set up TX/RX descriptor rings
    
    mtx_lock(softc + 0x3158, "if_mts.c:0x12f2");
    kthread_resume(softc[0x3150]);   // resume gbe:ctrl thread
    
    mtx_lock(softc + 0x3158);
    softc[0x3178] = 0x10000;          // set event flag
    cv_signal(softc + 0x3178);        // wake gbe:ctrl thread
    
    if (softc->carrier_polling_disabled == 0) {
        kthread_resume(softc[0x31a0]);  // resume gbe:phy_ctrl thread
        mtx_lock(softc + 0x31a8);
        softc[0x31c8] = 0x10100;      // event flags = AN + link-start
        cv_signal(softc + 0x31c8);    // wake gbe:phy_ctrl thread
    }
}
```

**Critical detail**: `softc[0x3178] = 0x10000` immediately after kthread_resume.
Flag 0x10000 = "re-initialize" for gbe:ctrl. And `softc[0x31c8] = 0x10100`
— flag 0x10000 = "re-run PHY init", flag 0x100 = "start AN monitoring".

---

## 3. The gbe:ctrl init thread (FUN_c85f1e80) — what it does at ifup

Decompile confirms. After mts_ifup resumes it:

1. Calls `mts_init_rings_kick()` — sets up TX/RX ring descriptors
2. If `softc+0x30dc != 0` (secondary-MAC enabled): sets BAR+0x80 bit 0 and
   does PHY config via `FUN_c85ef7d0(BAR, 0x80206910, 0)` — the if_init callback
3. If `softc+0x30e0 == 0` (carrier-polling **not** disabled): calls `mts_link_change(softc)`
   which reads `BAR+0x04` and reports link state to the OS
4. **Clears bit 12 of `BAR+0x54`** — `*BAR(BAR+0x54) &= 0xFFFFEFFF`
   This **disables the 0x1000 (RX packet ready) IRQ**.  This is a deliberate
   gate: RX IRQ stays masked until the ctrl thread de-masks it on a
   "link-up" event (event flag 0x2).

**Step 4 is new information.** Our driver should NOT keep BAR+0x54 bit 12
permanently enabled. Orbis only enables it when link is UP and traffic
is flowing.

---

## 4. The gbe:phy_ctrl thread (FUN_c85f0480) — the SMI heartbeat (confirmed)

Full decompile confirms the prior session's finding. The thread loops on
`msleep(cv, mtx, "gbe_phy_ctrl", HZ*3)` (3-second cadence). Each iteration:

- If no events: sleep HZ*3 (3 seconds), then process with timeout=0
- Event 0x10000 → re-trigger event 0x100
- Event 0x100: SMI C45 read of MMD 0x1e reg 0xa200 (twice), then
  SMI C22 read of BMSR (reg 1). If AN not complete after 200 iterations
  of 10ms delays, restart AN (BMCR write 0x1200).
- Event 0x1: Read `BAR+0x04`. If link bit 0 = 0 (link DOWN):
  read PHY reg 9 and 4, ensure AN advertise bits set, write BMCR 0x1200
  (restart AN). Mark `softc+0x31c9 |= 1` (link_was_down).
- Event 0x20000: system suspend cleanup.

The 3-second SMI poll is confirmed as the **MDIO heartbeat**.

---

## 5. What gates BAR+0x04 bit 0 (link_up)?

`mts_link_change` (FUN_c85eeb90) is a **passive reader** of `BAR+0x04`. It does:
```c
status = readl(BAR + 0x04);
if (status & 1) {
    speed = (status >> 2) & 3;  // 0=10M, 1=100M, 2=1000M
    duplex = ((status >> 4) & 1) * 2 + 1;  // 1=half, 3=full
    // encode into ifmedia bitfield
} else {
    // link down
}
```

There is **no write** to BAR+0x04 anywhere in the driver. The register is
purely a hardware status register reflecting the PHY's negotiated link
state through the SMI link status dirty-bit mechanism. For bit 0 to be 1,
the PHY must have completed auto-negotiation AND the MAC must be receiving
the PHY's link signal.

The link status register is updated by the MAC hardware based on the PHY's
real-time status. If the PHY (MT7531) doesn't forward traffic to the host
port, the MAC's link detector won't see a link.

---

## 6. FUN_c85f11c0 — MDIO switch management frame (new discovery)

`FUN_c85f11c0(softc, port, reg)` sends an **MDIO management frame** via the
hardware TX engine. This is NOT a normal SMI read/write. The function:

1. Constructs a 32-byte ethernet frame with:
   - Destination: `01:50:43:00:00:00` (Port0, broadcast) or MAC from `softc+0x30d6`
   - Source: `softc+0x30d6` bytes
   - Ethertype: `0xFA42`
   - Payload: opcode byte 0x0F, sequence counter, then frame data
   - For `port << 5 | reg`: writes SMI register address
2. Sends via `FUN_c85f1890` which:
   - Allocates an mbuf, copies frame
   - Sends via `FUN_c85f1aa0` (TX path)
   - **After TX: writes `BAR+0x34 | 4`** (RX restart kick bit)
   - Polls for up to 1000× 1ms delays for echo response
   - Reads response from `softc+0x310c` (64-byte response buffer)

The gbe:ctrl thread calls this with `(softc, 2, 0x13)` then `(softc, 3, 0x13)`
and then `(softc, 2, 0x13)` + `(softc, 3, 0x13)` again, sending standard
MDIO Clause 22 frames to switch ports 2 and 3 (internal switch management
addresses).

**This is MT7531's in-band management protocol.** The MT7531 switch forwards
management frames to its internal MDIO bus. Without this, the switch won't
configure its port routing.

The gbe:ctrl init also calls `FUN_c85f2250` which:
1. Calls `FUN_c85f11c0(softc, 2, 0x13)` — write port 2 reg 0x13
2. Calls `FUN_c85f11c0(softc, 3, 0x13)` — write port 3 reg 0x13
3. Constructs frame with ethertype `0xFA42`, opcode 0x800B — "switch reset"
4. Sends via FUN_c85f1890, checks if response bit 0 is set → "L2 switch has
   been reset"
5. Calls `FUN_c85f1010(ifp)` — `if_link_state_change` to update link state

---

## 7. FUN_c85f0910 — TX/RX ring reconfiguration with CRC multicast filter

This function (`if_transmit` path for multicast/CRC) does:

- Reads `BAR+0x10` (MAC_CTRL3)
- If `ifp->if_flags & IFF_PROMISC == 0`:
  - If `ifp->if_flags & IFF_ALLMULTI == 0`: clears bit 4 of BAR+0x10
  - Writes `BAR+0x1c = 0x80000000` (MCAST_HASH register with CRC start bit)
  - Loops up to 1M iterations polling `BAR+0x1c` for bit 0x20000 (hash done)
- If `ifp->if_flags & IFF_PROMISC != 0`:
  - Sets bit 4 of BAR+0x10 (promisc mode)
  - Writes `BAR+0x1c = 0x7000 + i` for i=0..0xFF (256 iterations —
    likely setting up multicast hash table for accept-all)

**BAR+0x10 bit 4** = promiscuous mode enable. This is important: it means
MAC_CTRL3 bit 4 controls whether the MAC accepts all frames regardless
of destination. In `mts_mac_init`, bit 4 is **cleared** (`0xFFFFFF6E` mask
clears bits 1,4,5,8). So the MAC starts in non-promisc mode.

---

## 8. Recommended v83 driver additions

Based on the full Orbis decompile, the standalone ps4_mts.c driver needs:

### Must-have for link-up
1. **MT7531 switch reset via C45**: Step 49 in mts_mac_init —
   `SMI_CL45_write(sc, MMD=7, reg=0, val=0)` after the PHY init block.
   This is the SW_RESET for the integrated switch. Without it, the switch
   port won't forward traffic to the host.

2. **BAR+0x004 clear speed bits**: Steps 34+47 — read BAR+0x04, mask off
   bits 12-13 and bits 8-9 (`val & 0x7FFFCFFF`). This forces speed to 10M
   before PHY init, then clears it again after PHY config.

3. **Post-PHY-init C45 writes**: Steps 50-51 and 25-33. The MMD 0x1e
   register accesses (0x096=0x8000, 0x037=0x33, etc.) are Realtek PHY
   trimming that must happen after the C22 register pokes.

4. **PHY BMCR restart AN**: Step 51, `SMI_CL22_write(sc, 0, BMCR | 0x1200)`.
   After all PHY configuration, restart auto-negotiation.

5. **BAR+0x054 bit 12 gate**: After MAC init, do NOT keep RX-ready IRQ enabled.
   Only enable it when link comes up. Orbis gates it on event 0x2 in gbe:ctrl.

6. **Periodic SMI poll**: Must have a kernel thread (or timer with workqueue)
   that reads BMSR (PHY reg 1) every ~3 seconds. This keeps MDC clocked AND
   detects link state changes.

7. **Switch management frame**: Send MDIO management frames via BAR+0x1C/TX
   path to reset/program the MT7531 switch — `FUN_c85f11c0` and `FUN_c85f2250`.
   This requires the TX path to be working, so it's phase-2+.

### Nice-to-have
- BAR+0x00c bit 7 clear (MAC_CTRL2) — from step 56
- BAR+0x074 = 0x2277 (MAC_PAUSE) — from step 57
- BAR+0x008 |= 0x07597C00 (MAC_CTRL feature bits) — from step 58
- BAR+0x010 = (val & 0xFFFFFF6E) | 0x81 — MAC_CTRL3: clear bits 1,4,5,8; set bits 0,7

### Specific PHY register writes from mts_mac_init efuse block
If `efuse(0x6c) & 0x80800000 == 0x80800000` (real hardware always passes this
— it's the "trim data valid" flag), the efuse calibration table at
`DAT_ffffffffc8b59a80` (0x7f, 0x7f, ..., 0x00) is indexed by efuse values
and written to MMD 0x1e registers 0x172–0x180 and 0x120/0x160/0x170.
For a first-pass driver, these can likely be skipped; the MT7531's default
trim should work, and mainline `mtk-ge.c` doesn't do these.

---

## Recommended next experiment on hardware

In the v83 standalone driver, after `mts_mac_init`-equivalent register
sequence, add:
```c
// Step 49 — MT7531 switch reset via C45
smi_cl45_write(sc, 0x3c0007, 0);   // MMD dev 7, reg 0, val 0 = SW_RESET

// Step 51 — Restart AN
bmcr = smi_cl22_read(sc, 0);
smi_cl22_write(sc, 0, bmcr | 0x1200);

// Then add a 3-second SMI poll timer
```
If the MT7531 switch needs the in-band management frame (0xFA42 ethertype),
link will not come up until the TX path works. In that case, link-up requires
phase-2 (TX) first.