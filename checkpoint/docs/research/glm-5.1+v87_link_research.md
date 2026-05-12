# v87 Link research — glm-5.1, 2026-05-13

## Lead finding: Orbis configures the MT7531 switch ports over in-band MDIO management frames (ethertype 0xFA42), AND the gbe:ctrl thread does a 70-iteration link-up poll with TX management frames before declaring success

The BMSR bit 2 (link status) goes through the PHY and the MAC's internal
link detector.  On Baikal, `BAR+0x04 bit 0` reflects a hardware state machine
that combines: (a) the PHY's AN-complete signal, (b) the MAC's PCS sync, and
(c) possibly a switch-port-forwarding signal from the MT7531.  Orbis's
`gbe:ctrl` thread runs a **70-iteration loop** (up to `0x46 = 70` iterations,
each with a 1ms delay) polling `BAR+0x04 & 1` to detect link-up.  If link
comes up during this poll, it sends a management frame and proceeds to the
switch-reset sequence.

The switch-reset sequence (`FUN_c85f2250`) writes to switch port registers
`2`, `3`, and `4` via `FUN_c85f11c0` (ethertype `0xFA42` management frames).
Then it sends a reset command (opcode `0x800B`), followed by a confirmation
(opcode `0x600B`), and checks for "L2 switch has been reset."

**Without these management frames, the MT7531 switch probably does not
enable its host-facing port, and the PHY's link signal never propagates
to BAR+0x04.**

---

## Q1 — PMA / PCS enable (MMD 1, MMD 3)

Decompiled `mts_mac_init` (FUN_c85ecb60) end-to-end. **There are ZERO
C45 accesses to MMD 1 (PMA/PMD) or MMD 3 (PCS).** Every C45 access in
mts_mac_init targets MMD 0x1e or MMD 0x1f (Realtek vendor MMDs) or MMD 7
(switch management). No code in gbe:ctrl or gbe:phy_ctrl touches MMD 1 or 3.

The gbe:phy_ctrl thread (FUN_c85f0480) event 0x100 handler reads:
```c
mts_smi_cl45_read(sc, 0xa2001e, &val);  // MMD 0x1e, reg 0xa200
```
Not MMD 1.

**Conclusion for Q1:** Orbis does NOT write to PMA_POWER_DOWN (MMD 1 reg 0 bit 11)
or PCS_CONTROL_1 (MMD 3 reg 0). The MT7531's PMA and PCS are left in their
default power-on state. The PHY is NOT in software power-down.

---

## Q2 — Master/Slave configuration

The gbe:phy_ctrl thread event 0x1 (link-change) handler does:

```c
// FUN_c85f0480 @ 0xc85f0480, event 0x1
if (!(BAR_0x04 & 1)) {                        // link DOWN
    mts_smi_cl22_read(sc, 9, &reg9);          // read autoneg advert
    mts_smi_cl22_read(sc, 4, &reg4);          // read autoneg cap
    if (!(reg9 & 0x200))                       // if 1000BT-full not advertised
        mts_smi_cl22_write(sc, 9, reg9 | 0x200);  // advertise 1000BT-full
    if (!(reg4 & 0x180))                       // if pause not advertised
        mts_smi_cl22_write(sc, 4, reg4 | 0x180);  // advertise pause
    bmcr = mts_smi_cl22_read(sc, 0);
    mts_smi_cl22_write(sc, 0, bmcr | 0x1200);  // restart AN
}
```

Orbis **only sets bit 9 (0x200 = 1000BT full-duplex) in reg 9**. It never
sets bits 11-12 (1000BT master/slave configuration). This means the PHY
advertises 1000BT-full-duplex without specifying master or slave preference,
which per IEEE 802.3 Clause 40 means "slave preferred."

The event 0x100 AN-recovery handler is similar — when AN fails (BMSR bit 5
clear after 200 × 10ms = 2 seconds):
```c
// FUN_c85f0480 @ event 0x100
mts_smi_cl22_read(sc, 9, &reg9);
reg9_clear = reg9 & 0xFDFF;  // clear bit 9
if (reg9 & 0x200)              // if 1000BT was previously advertised
    reg9_clear = reg9 | 0x200; // re-advertise 1000BT
mts_smi_cl22_write(sc, 9, reg9_clear);
```

**Conclusion for Q2:** Orbis never forces master or slave mode. It only
advertises bit 9 (1000BT full-duplex) in reg 9. If partner reg 5 = 0xc5e1
doesn't include 1000BT, the PHY should fall back to 100BT. The M/S fault bit
(bit 13 of reg 10) should not be set in this configuration.

However, the C45 write at mts_mac_init step 35 (`C45_write(0x189001e, 0x110)`)
writes MMD 0x1e reg 0x189 = value 0x110. This register is in the Realtek
vendor MMD. On MT7531 it may map to a different function than on RTL8211.
If this write inadvertently sets an M/S force bit on MT7531, it could cause
the AN cycling.

---

## Q3 — RGMII / SGMII / interface-mode configuration

Scanning all C45 writes in `mts_mac_init` that target MMDs other than 0x1e
and 0x1f:

| Encoding | Actual MMD/reg/val | Purpose |
|----------|-------------------|---------|
| `0x3c0007` | MMD 7 reg 0, val 0 | **Switch SW_RESET** |
| `0xe0001e` | MMD 1e reg 0xe000 | efuse LSB trim |
| `0xa2001e` | MMD 1e reg 0xa200 | C45 read in gbe:phy_ctrl |
| `0x115001f` | MMD 1f reg 0x115 | efuse |
| `0x0e0001e` | MMD 1e reg 0xe000 | (same as above, duplicate) |
| `0x147001e` | MMD 1e reg 0x147 | efuse trim |
| `0x12001e` | MMD 1e reg 0x120 | impedance |
| `0x16001e` | MMD 1e reg 0x160 | impedance |
| `0x17001e` | MMD 1e reg 0x170 | amplitude |
| `0x18001e` | MMD 1e reg 0x180 | amplitude |
| `0x19001e` | MMD 1e reg 0x190 | amplitude |
| `0x20001e` | MMD 1e reg 0x200 | amplitude |
| `0x21001e` | MMD 1e reg 0x210 | amplitude |
| `0x22001e` | MMD 1e reg 0x220 | amplitude |
| `0x096001e` | MMD 1e reg 0x096 | LED/calibration |
| `0x037001e` | MMD 1e reg 0x037 | LED/calibration |
| `0x174001e` | MMD 1e reg 0x174 | TX amplitude trim |
| `0x175001e` | MMD 1e reg 0x175 | TX amplitude trim |
| `0x172001e` | MMD 1e reg 0x172 | TX amplitude trim |
| `0x173001e` | MMD 1e reg 0x173 | TX amplitude trim |
| `0x330001e` | MMD 1e reg 0x330 | post-AN control |
| `0x171001e` | MMD 1e reg 0x171 | TX/RX config |
| `0x122001e` | MMD 1e reg 0x122 | unknown |
| `0x268001f` | MMD 1f reg 0x268 | **MT7531-specific** |
| `0x189001e` | MMD 1e reg 0x189 | unknown |

All C45 writes target MMD 0x1e (Realtek vendor), MMD 0x1f (Realtek extended),
or MMD 7 (switch). **None target MMD 1 or MMD 3.**

The only non-1e/1f/7 C45 write is `0x3c0007` (MMD 7, switch reset).
The `0x268001f` write (MMD 0x1f reg 0x268 = 0x7f4) is to the Realtek
vendor MMD, but on MT7531 this maps to a different register.

**No TX_DELAY / RX_DELAY / SKEW configuration is done via MDIO.** The MAC
does BAR+0x07c = 25000000 (25 MHz reference clock) and BAR+0x030 = 0x10100
(MAC_MODE). The interface mode (RGMII vs SGMII vs MII) is implicit in the
PHY's hardware strapping, not configured by MDIO.

**Conclusion for Q3:** Orbis does NOT configure RGMII/SGMII timing delays
via MDIO. These are likely set by hardware strap pins on the MT7531 or by
a SiLabs/efuse configuration set at board level.

---

## Q4 — Interface mode select

No C22 or C45 register write in any of the decompiled functions
resembles an "interface mode select." The `BAR+0x030 = 0x10100` (MAC_MODE)
is the only MAC-side configuration that could encode interface mode, and its
value is fixed.

**Conclusion for Q4:** Interface mode is not explicitly selected by the
driver. It's determined by hardware strapping.

---

## Q5 — In-band switch management frames (required for link?)

This is the most detailed finding. The gbe:ctrl thread init function
`FUN_c85f1e80` does, when carrier polling is enabled (`softc+0x30e0 == 0`,
which is the default):

### Phase 1: Poll BAR+0x04 for link (up to 70 iterations, ~70ms)

```c
// FUN_c85f1e80 @ 0xc85f1e80, carrier_polling != 0 path
for (int i = 0x46; i > 0; i--) {  // 0x46 = 70
    uint link_status = readl(BAR + 0x04);
    if (link_status & 1) {  // link UP detected!
        // Send "status query" management frame to switches
        mdelay(1);
        construct_frame(ethertype=0xFA42, opcode=0x0F, dst="01:50:43:00:00:00",
                        src=softc+0x30d6, data=0x20 bytes);
        tx_result = FUN_c85f1890(softc, frame, 0x22);
        if (tx_result == 0) {
            // Read response: extract 2 bytes from response at offsets 0x5e-0x5f
            softc+0x310a = response_bytes[0];
            softc+0x310b = response_bytes[1];
        }
        break;
    }
    mdelay(1);
}
```

### Phase 2: Switch reset and port configuration

```c
FUN_c85f2250(softc);  // the "switch_init" function
```

`FUN_c85f2250` (at 0xc85f2250) does:
1. `FUN_c85f11c0(softc, 2, 0x13)` — write MDIO reg 0x13 to switch port 2
2. `FUN_c85f11c0(softc, 3, 0x13)` — write MDIO reg 0x13 to switch port 3
3. `FUN_c85f11c0(softc, 4, 0x13)` — write MDIO reg 0x13 to switch port 4
4. Send management frame with ethertype `0xFA42`, opcode `0x800B` (switch reset request)
5. Send management frame with ethertype `0xFA42`, opcode `0x600B` (switch reset confirm)
6. Check response byte for bit 0 → print "L2 switch has been reset."
7. Call `if_link_state_change(ifnet)` → update OS link state

The port register 0x13 in MT7531 is the **Port Control register**. The
standard MT7531 port control register at offset 0x13 contains:
- Bits 0-1: Port STP State (0=disabled, 1=blocking, 2=learning, 3=forwarding)
- Bit 2: Unknown unicast flood
- Bit 3: Unknown multicast flood
- Bit 4: Unknown IPv4 multicast flood

Writing 0x13 = forcing value 0x13 = STP state forwarding (bits 0-1 = 0b11)
+ unknown unicast/multicast flood enable.

**The management frames use the MT7531's in-band management protocol.** They
are NOT normal ethernet frames — they go through the Baikal MAC TX path
(yes, even before link is up) using `FUN_c85f1890` which sets up a TX
descriptor. After TX, it kicks `BAR+0x34 | 4` (RX restart) and polls for
a response.

This means: **the gbe:ctrl thread sends TX frames before the OS considers
the interface "up."** The TX path must be functional before link establishment.

### Phase 3: Clear BAR+0x54 bit 12

```c
*(BAR + 0x54) &= 0xFFFFEFFF;  // disable RX-ready IRQ
softc+0x3099 &= ~0x10;         // clear "rx_poll_active" flag
```

This gates RX processing until link-up event processing begins.

### Is this required for link?

**Almost certainly yes.** The MT7531 switch needs to be told that its ports
should be in "forwarding" state. Without the management frame setting STP
state to forwarding, the switch blocks traffic on the host port, and the
PHY's link signal doesn't propagate through the switch fabric.

However, there's a chicken-and-egg problem: the management frame is sent
**only after BAR+0x04 bit 0 is detected** (i.e., link must already be UP
at the PHY level first). If the PHY's link never comes up on its own, the
switch configuration never happens.

The v87 prompt states "PHY auto-negotiation completes, partner advertises,
but BMSR bit 2 never sets." This means either:
1. The PHY is reporting AN-complete but the actual electrical link is not up
   (the PHY's link LED equivalent doesn't turn on), OR
2. The link IS up at the PHY but the Baikal MAC doesn't reflect it in BAR+0x04

If the link is up at the PHY but BAR+0x04 bit 0 stays 0, it could mean the
MAC's internal PCS/PMA doesn't see synchronization because it needs specific
register configuration. Looking at BAR register semantics:

---

## Q6 — Other "force link up" mechanisms

### Writes to BAR+0x04

The only write to BAR+0x04 in mts_mac_init is the R/M/W that clears bits
12-13 and 8-9 (`val & 0x7FFFCFFF`). No code ever writes a value to BAR+0x04
that sets bit 0. The register is purely a status read from MAC hardware.

The gbe:ctrl event 0x2 handler **reads** BAR+0x04 but also:
```c
// BAR+0x54 &= 0xFFFFEFFF  // clears bit 12 (disable RX-ready IRQ)
```
This means link-change event processing disables receive interrupts until the
OS is ready to process packets.

### BAR+0x030 (MAC_MODE) = 0x10100

Decoding: `0x10100` = bit 8 (0x10000) | bit 8 (duplicate?) | bit 8.
Actually: `0x10100` = `0x10000 | 0x100 | 0x00`. Bits 8 (MAC enable?) and
16 (MAC enable?), + bit 8. This is疑似 "MAC_RX_ENABLE | MAC_TX_ENABLE"
or similar. If bit 8 is TX enable and bit 16 is RX enable, then the MAC has
both directions enabled after mac_init.

But wait — the value `0x10100` written to BAR+0x030 more likely means:
- `0x10000` = receive enable
- `0x100` = transmit enable
- `0x0` = speed 10M

This is consistent with the MAC_MODE register being enabled for both TX and RX.
If our driver doesn't write 0x10100 to BAR+0x030, the MAC won't process
incoming link signals.

### BAR+0x07c (MAC_CLK) = 25000000

Sets the MAC's reference clock to 25 MHz. This is required for the MAC's
internal state machines. If we don't write this, the MAC's link detector
may not work.

### BAR+0x008 (MAC_CTRL) |= 0x07597C00

This OR value sets many bits at once. Breaking down `0x07597C00`:
- Bit 26 (0x4000000): unknown
- Bit 25 (0x2000000): unknown
- Bit 24 (0x1000000): unknown
- Bit 22 (0x400000): unknown
- Bit 21 (0x200000): unknown
- Bit 20 (0x100000): unknown
- Bit 19 (0x80000): unknown
- Bit 18 (0x40000): unknown
- Bit 17 (0x20000): unknown
- Bit 16 (0x10000): unknown
- Bit 14 (0x4000): unknown
- Bit 13 (0x2000): unknown
- Bit 12 (0x1000): unknown
- Bit 10 (0x400): unknown

If any of these bits are "RX enable", "TX enable", "link detection enable",
or "PCS enable", then not writing this would prevent link status from updating.

### BAR+0x010 (MAC_CTRL3) = (val & 0xFFFFFF6E) | 0x81

Clearing bits 1, 4, 5, 8 and setting bits 0 and 7. If bit 0 is "MAC enable"
and bit 7 is something like "link detection enable", this is critical.

### BAR+0x1D4 = 1

Unknown register. If this gates link detection, not writing it would prevent
BAR+0x04 bit 0 from ever setting.

### BAR+0x0AC = 9

Unknown register. Could be a power/clock gate.

### The gbe:ctrl link-UP detection loop

The critical sequence in `FUN_c85f1e80` when carrier polling is disabled
(`softc+0x30e0 != 0`) is:

```c
// Poll BAR+0x04 for link, up to 70 iterations
for (int i = 70; i > 0; i--) {
    if (BAR_0x04 & 1) {
        // Link detected - send management frame
        break;
    }
    mdelay(1);
}
// Then unconditionally run switch reset
FUN_c85f2250(softc);
// Then clear BAR+0x54 bit 12
```

When carrier polling IS enabled (the default, softc+0x30e0 == 0):
`mts_link_change()` is called instead, which just reads BAR+0x04 and reports
to OS — no switch management frames.

---

## Recommended v87 experiment on hardware

The most likely cause of BMSR bit 2 staying 0 while AN completes is one of:

1. **The PHY needs the MAC's TX clock (RGMII TXC) to be driven** before it
   reports link-up. On Baikal, TXC comes from BAR+0x07c (25 MHz reference)
   gated through MAC_CTRL bits. If TX isn't started (`BAR+0x030 = 0x10100`
   and BAR+0x008 |= 0x07597C00`), the PHY doesn't see a valid RGMII TXC
   and won't report link-up.

2. **BAR+0x030 needs to be written with MAC_MODE = 0x10100** before the
   PHY can see a valid MAC-side RGMII signal. If we wrote this too late or
   not at all, the PHY's link detection logic won't see synchronization.

3. **BAR+0x1D4 = 1** or **BAR+0x0AC = 9** may be required before the
   internal link state machine activates.

The immediate test: in the v87 driver, after mts_mac_init equivalent,
add writes in this specific order:
```c
writel(0x00000000, BAR + 0x200);  // step 1: master reset
writel(0x07597C00 | readl(BAR+0x008), BAR + 0x008);  // MAC_CTRL
writel(0x00FFFFFFE & readl(BAR+0x00C), BAR + 0x00C); // MAC_CTRL2
writel(0xFFFFFF6E & readl(BAR+0x010) | 0x81, BAR + 0x010); // MAC_CTRL3
writel(0x10100, BAR + 0x030);  // MAC_MODE: TX+RX enable
writel(25000000, BAR + 0x07C);   // MAC_CLK
writel(1, BAR + 0x1D4);          // unknown enable
writel(9, BAR + 0x0AC);          // unknown enable
writel(0x2277, BAR + 0x074);     // MAC_PAUSE
```
then poll BAR+0x04 for bit 0.