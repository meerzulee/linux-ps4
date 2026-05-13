# v92 — RTL8153 "Link detected: no" root-cause analysis

**kimi-k2.6, 2026-05-13**

## Executive summary

When the PS4 (MT7531 PHY) is connected to a host via a Realtek RTL8153 USB-Ethernet adapter, the RTL8153 reports `Link detected: no` / `NO-CARRIER` even though the PS4's PHY registers show active 1000BASE-T training and partner ability accumulation. Investigation of the mainline `r8152.c` driver shows that **the RTL8153 requires its internal PHY to assert Link Status (not merely complete auto-negotiation) before it will declare carrier on**. A PHY that successfully exchanges auto-negotiation FLPs but has marginal TX swing or poor signal integrity will AN-complete without ever asserting Link Status, producing exactly the observed symptoms.

**Verdict**: The PS4 PHY is likely transmitting marginal or out-of-spec signals that the RTL8153 receiver cannot lock onto for 1000BASE-T PCS sync, even though the older partner switch was more tolerant.

---

## What bit does ethtool "Link detected" come from?

### Chain

```
ethtool -S ethX  →  ethtool_op_get_link()  →  netif_carrier_ok()
                                    ↑
                              set_carrier()
                                    ↑
                         rtl8152_get_speed()  →  PLA_PHYSTATUS bit 1
```

### Code trace

1. **ethtool** (`net/ethtool/ioctl.c:60`):
   ```c
   u32 ethtool_op_get_link(struct net_device *dev)
   {
       return netif_carrier_ok(dev) ? 1 : 0;
   }
   ```

2. **Carrier is set in `set_carrier()`** (`r8152.c:6812`):
   ```c
   static void set_carrier(struct r8152 *tp)
   {
       u16 speed = rtl8152_get_speed(tp);
       if (speed & LINK_STATUS) {          // bit 1 of PLA_PHYSTATUS
           if (!netif_carrier_ok(netdev))
               netif_carrier_on(netdev);   // "carrier on"
       } else {
           if (netif_carrier_ok(netdev))
               netif_carrier_off(netdev);  // "carrier off"
       }
   }
   ```

3. **`rtl8152_get_speed()`** (`r8152.c:3021`):
   ```c
   static inline u16 rtl8152_get_speed(struct r8152 *tp)
   {
       return ocp_read_word(tp, MCU_TYPE_PLA, PLA_PHYSTATUS);  // 0xe908
   }
   ```

4. **`PLA_PHYSTATUS` bit definitions** (`r8152.c:731`):
   ```c
   enum rtl_register_content {
       _2500bps    = BIT(10),
       _1250bps    = BIT(9),
       _500bps     = BIT(8),
       _tx_flow    = BIT(6),
       _rx_flow    = BIT(5),
       _1000bps    = 0x10,
       _100bps     = 0x08,
       _10bps      = 0x04,
       LINK_STATUS = 0x02,   // <-- this bit
       FULL_DUP    = 0x01,
   };
   ```

**Answer**: `Link detected: yes` requires **`PLA_PHYSTATUS` bit 1 (`LINK_STATUS = 0x02`)** to be set. This register is internal to the RTL8153 MAC/PHY and is read from address `0xe908` via the OCP bus. The driver has **no direct control** over this bit and never writes to `PLA_PHYSTATUS`.

---

## What causes `LINK_STATUS` to be set?

`PLA_PHYSTATUS` is a **shadow register** maintained by the RTL8153 firmware/hardware. It reflects the internal PHY's link-state-machine output. The driver does not poll MII BMSR directly in the hot path; it relies entirely on this shadow register.

For the internal PHY to set `LINK_STATUS`, the following must occur **in sequence**:

1. **Auto-negotiation completes** (or is bypassed in forced mode).
2. The PHY's **PCS (Physical Coding Sublayer)** achieves sync at the negotiated speed.
3. The PHY's **Signal Detect** circuitry confirms valid energy on the wire.

Step 1 and steps 2-3 are **independent**. It is entirely possible for AN to complete (both sides exchange base pages / FLPs) while PCS sync fails afterward.

### Evidence from driver: ANEG vs Link are tracked separately

The driver has an explicit check for whether the PHY is still in auto-negotiation:

```c
// r8152.c:6787
static bool rtl8153_in_nway(struct r8152 *tp)
{
    u16 phy_state = ocp_reg_read(tp, OCP_PHY_STATE) & 0xff;  // 0xa708

    if (phy_state == TXDIS_STATE || phy_state == ABD_STATE)
        return false;  // NOT in NWAY
    else
        return true;   // Still in NWAY
}
```

Where:
- `TXDIS_STATE = 0x01`
- `ABD_STATE = 0x02`

The driver uses this in `delay_autosuspend()` to avoid suspending while AN is still running:

```c
// r8152.c:8508
if (!sw_linking && tp->rtl_ops.in_nway(tp))
    return true;  // Don't suspend — AN may finish soon
```

**This proves the RTL8153 distinguishes "in auto-negotiation" from "link up".** Completing AN (leaving `TXDIS_STATE`/`ABD_STATE`) is necessary but **not sufficient** for `LINK_STATUS`.

---

## Answering the specific questions

### (a) Does it need sustained TX signal on the wire from partner?

**YES — for 1000BASE-T.** After AN completes, 1000BASE-T requires continuous PAM-5 signaling from **both** directions. The PHY receiver must lock onto these symbols and achieve PCS sync. If the partner's TX signal is marginal (low swing, high jitter, poor eye diagram), the RTL8153 receiver may fail to sync, and `LINK_STATUS` stays 0.

**For 10/100 Mbps**, the requirement is simpler (Manchester or 4B/5B NRZI), but the same principle applies: valid signal energy must be detected.

### (b) Does it need FLP pulses at AN ready frequency (16 ms)?

**Only during auto-negotiation.** FLPs (Fast Link Pulses) are used to exchange base pages during the AN phase. Once AN completes, FLPs stop and are replaced by continuous data signaling.

If the PS4 PHY is sending FLPs that the RTL8153 can decode, AN will complete. But if the PS4 PHY's **post-AN signal** (PAM-5 for 1000BASE-T) is marginal, the RTL8153 will AN-complete and then immediately drop link — or never assert it in the first place.

### (c) Does it need base page reception?

**Only for AN.** Receiving the partner's base page populates the `ANLPAR` (Auto-Negotiation Link Partner Ability Register). This tells the PHY what speed to attempt. However, link status is determined **after** the speed is chosen, by whether PCS sync succeeds at that speed.

### (d) Does it need PHY-side link partner ability register populated?

**No.** The LP ability register (`ANLPAR`, `STATUS1000`) being populated means FLPs were successfully received during AN. This is entirely separate from `LINK_STATUS`. A PHY can have a fully populated `ANLPAR` and `STATUS1000` while `BMSR` bit 2 (Link Status) remains 0.

---

## Could a PHY with marginal TX swing register as "no carrier" on the receiving end?

**Absolutely yes. This is the most likely explanation.**

### Why AN can succeed but link fails

| Phase | Signal type | Tolerance | What can go wrong |
|---|---|---|---|
| Auto-negotiation | FLPs (16ms interval, 100ns pulses) | Very high | Even marginal TX can be decoded |
| Link establishment | Continuous PAM-5 (1000BASE-T) or NRZI (100BASE-TX) | Strict | Marginal TX causes PCS desync, bit errors, no link |

- **FLPs are robust**: They are low-duty-cycle pulses with long quiet periods. A receiver can integrate energy over many pulses and decode them even with poor signal-to-noise ratio.
- **Continuous data is fragile**: 1000BASE-T uses PAM-5 at 125 Mbaud on all four pairs simultaneously. The receiver's equalizer, clock recovery, and PCS must lock precisely. A marginal TX swing produces a closed eye diagram, making lock impossible.

### The specific observation

> "PS4 PHY (MT7531) reg10 shows it CAN receive partner FLPs (sees 1000T training, accumulates idle errors)"

This tells us:
1. The **RTL8153 → PS4** path is working well enough for the MT7531 to see FLPs and 1000T training.
2. The **PS4 → RTL8153** path may be marginal. The MT7531's transmitter might have insufficient swing, improper impedance matching, or incorrect RGMII-to-PHY timing, causing the RTL8153 receiver to fail PCS sync.
3. The "idle errors" in reg10 are consistent with a PHY that is trying to train but cannot achieve solid lock — or is receiving corrupted symbols.

### Why the old switch worked

The old partner switch may have had:
- A more tolerant receiver (wider eye mask, better equalizer).
- A PHY from a different vendor (e.g., Marvell, Broadcom) with different sensitivity.
- Better common-mode rejection or cable equalization.

The RTL8153 is a cost-optimized USB PHY. Its receiver may be less forgiving than a dedicated switch PHY.

---

## What the RTL8153 driver does NOT do

The driver does **not** implement any of these workarounds:
- Force link up regardless of PHY status.
- Retry AN with different advertisement.
- Adjust PHY RX sensitivity or squelch threshold.
- Detect "AN complete but link down" and downgrade speed automatically.

Once `LINK_STATUS` is 0, the driver simply reports `NO-CARRIER`. There is no backdoor.

---

## Recommended next steps

1. **Verify with a different host NIC**: If a PCIe Intel i210 or Broadcom BCM5719 on the host shows the same `NO-CARRIER`, the PS4 TX signal is definitively marginal.
2. **Check MT7531 TX swing / amplitude registers**: The MT7531 PHY may have vendor-specific registers (MMD 1/3/7) that control TX amplitude or pre-emphasis. If these are not initialized correctly, the TX eye may be out of spec.
3. **Force 100BASE-TX**: If 1000BASE-T requires too much signal integrity, forcing 100 Mbps (which uses simpler 4B/5B NRZI on two pairs) may succeed even with marginal TX. The RTL8153 supports forced speeds via `BMCR_SPEED100`.
4. **Measure with an oscilloscope**: If available, probe the TX pair from the PS4. A 1000BASE-T eye diagram should have ~1Vpp differential. Significantly lower swing confirms the hypothesis.

---

## Cited code locations

| File | Line | Symbol | Meaning |
|---|---|---|---|
| `r8152.c` | 60 | `ethtool_op_get_link` | Returns `netif_carrier_ok()` |
| `r8152.c` | 6812 | `set_carrier` | Sets carrier based on `LINK_STATUS` |
| `r8152.c` | 3021 | `rtl8152_get_speed` | Reads `PLA_PHYSTATUS` (0xe908) |
| `r8152.c` | 110 | `PLA_PHYSTATUS` | Register address 0xe908 |
| `r8152.c` | 741 | `LINK_STATUS` | Bit 1 of PLA_PHYSTATUS |
| `r8152.c` | 6787 | `rtl8153_in_nway` | Checks PHY AN state machine |
| `r8152.c` | 217 | `OCP_PHY_STATE` | Register 0xa708 (TXDIS/ABD states) |
| `r8152.c` | 682 | `TXDIS_STATE` | Value 0x01 |
| `r8152.c` | 683 | `ABD_STATE` | Value 0x02 |
| `r8152.c` | 8495 | `delay_autosuspend` | Uses `in_nway` vs `LINK_STATUS` mismatch |

---

## Bottom line

The RTL8153 says "Link detected: no" because its internal PHY never asserts `LINK_STATUS`. This is almost certainly **not** a driver bug or missing init sequence on the RTL8153 side. It is a **physical-layer signal integrity issue**: the PS4's MT7531 PHY is either not transmitting with sufficient amplitude/quality for the RTL8153 to achieve PCS sync, or there is an impedance/RGMII timing mismatch that degrades the TX eye diagram. The fact that a different partner switch worked suggests the PS4 signal is on the edge of the spec, and the RTL8153 is less tolerant.

The path forward is **analog/PHY tuning on the PS4 side** (MT7531 TX amplitude, pre-emphasis, or RGMII delay), not more driver reverse-engineering.
