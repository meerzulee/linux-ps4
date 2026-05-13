# deepseek+v92_phy_tx_diag.md — 2026-05-13

**Brutal bottom line first: cable swap confirming PHY TX is electrically
silent shatters the "MAC link-latch" framing.  The PHY cannot transmit —
this is a PHY-level problem, not a MAC-level status-reporting problem.
The partner can see FLP (AN base pages succeed), but high-speed data TX
is dead.  This is most likely caused by the MT7531 switch's per-port
PMCR register having MAC_TX_EN=0 (POR default after Orbis's GPIO switch
reset via BAR+0xf04).  Without TX path or in-band management frames to
reconfigure PMCR, we cannot fix this from software.  Phase 3 TX to send
management frames is the ONLY remaining software path.**

## (1) MAC TX_CLK output enable — no register found in Orbis path

Audited every BAR write in:
- `mts_mac_init` (`0xffffffffc85ecb60`) — 20 writes, none touch TX_CLK
- `mts_init_rings_kick` (`0xffffffffc85ef1b0`) — 7 writes:

```
BAR+0x044 = TX_desc_hi        (DMA config, not clock)
BAR+0x03c = TX_desc_lo        (DMA config, not clock)
BAR+0x048 = RX_desc_hi        (DMA config, not clock)
BAR+0x040 = RX_desc_lo        (DMA config, not clock)
BAR+0x034 |= 1                (RX engine start — sets bit 0)
BAR+0x038 |= 1                (TX engine start — sets bit 0)
BAR+0x054 = irq_mask_shadow   (IRQ config)
```

None of these are TX_CLK output enable.  The Baikal MAC clocking might be:
- Derived directly from PCIe refclk (no software gate needed)
- Gated by BAR+0x07c (25MHz clock ref, already written)
- Gated by MAC_MODE BAR+0x030 (0x10100, already written)
- Auto-enabled when TX engine is started (BAR+0x038 bit 0)

The TX_CLK likely auto-starts with the TX engine.  If the PHY is silent
despite BAR+0x038 bit 0 = 1, the problem is PHY-side, not MAC TX_CLK.

**Finding: no missed MAC TX_CLK register exists in Orbis.**

## (2) MT7531 force-TX diagnostic — three approaches

### A. PHY loopback (MMD 0, reg 0 — BMCR)

Standard BMCR bit 14 = loopback.  This loops TX back to RX internally.
```c
u16 bmcr = smi_cl22_read(dev, 0);
bmcr |= BIT(14);  // loopback
smi_cl22_write(dev, 0, bmcr);
```

After loopback, read BMSR bit 0 (extended capability) and verify
internal loopback works.  If internal loopback fails, the PHY's baseband
is completely dead.

### B. Force 100TX full-duplex with TX driver ON

```c
// Disable AN, force 100TX FD
u16 bmcr = smi_cl22_read(dev, 0);
bmcr &= ~BIT(12);           // disable AN
bmcr |= BIT(13);            // set speed=100
bmcr |= BIT(8);             // set full duplex
bmcr &= ~BIT(11);           // clear power-down
smi_cl22_write(dev, 0, bmcr);
```

This should force the PHY to drive 100TX MLT-3 signals immediately
without AN.  Partner (RTL8153) should see energy on the line.

### C. Near-end loopback via MT7531 vendor register

MT7531 has a vendor specific near-end loopback in MMD 0x1f (VEND2).
From `mt7531_phy_config_init` (mtk-ge.c), the PHY core PLL must be ON
(already confirmed v86).  Additional test-mode register:

```
MMD 0x1f reg 0x11: bit 0 = force TX driver on
```

Check if setting this bit makes the partner see TX energy.

### BIST approach from mainline

Mainline MT7531 has no exposed BIST.  The `mt7531_phy_config_init` only
sets DSP timing parameters (SlvDPSready, TX delay, MSE thresholds).
The closest diagnostic is `genphy_loopback()` which does standard BMCR
loopback.

## (3) BAR+0x09c bit 6 — TX engine reset

The Orbis ISR (`mts_intr`, `0xffffffffc85edcf0`) toggles bit 6 during
error recovery for IRQ status bit 0x500000 (packet engine error):

```c
// from mts_intr decompile:
uVar5 = in(BAR+0x09c);
uVar5 = uVar5 & 0xffffffbf;    // clear bit 6 → engine reset asserted
out(BAR+0x09c, uVar5);
uVar5 = in(BAR+0x09c);
uVar5 = uVar5 | 0x40;          // set bit 6 → engine reset released
out(BAR+0x09c, uVar5);
// Then: drain TX ring, re-program TX_DESC_BASE, kick RX restart
```

Bit 6 = **packet-engine reset** (0 = reset, 1 = normal).  The ISR
pulses it low→high to reset the engine after an error.

We write `0x6f` to BAR+0x09c during init (from Orbis replay).  This has
bit 6=1 (normal).  If the engine got stuck from some earlier operation,
pulsing bit 6 might recover it:

```c
writel(0x2f, BAR + 0x09c);  // bit 6 = 0 → engine reset
udelay(1000);
writel(0x6f, BAR + 0x09c);  // bit 6 = 1 → release reset
```

This would reset the TX engine state machine.  If the TX engine was
stuck and preventing TX_CLK output, this pulse might fix it.

**However:** the Orbis ISR also drains the TX ring and re-programs
BAR+0x03c/0x44 after the reset pulse.  Just toggling bit 6 without
re-programming the ring might leave the engine in an undefined state.

## Why the PHY TX is silent — the switch PMCR theory

The new cable-swap evidence changes the diagnosis fundamentally:

1. AN completes (partner sees FLP) → PHY can send low-speed pulses
2. Data TX is silent → PHY cannot drive high-speed signals
3. PHY RX works (sees partner's AN pages and training signals)

On MT7531, the per-port PMCR register (C22 address 0x13 at the switch's
port address) controls the MAC TX path:

From `mt7530.h:350-351`:
```
#define PMCR_MAC_TX_EN    BIT(14)   // MAC TX enable
#define PMCR_MAC_RX_EN    BIT(13)   // MAC RX enable
```

After switch reset (BAR+0xf04 GPIO toggle from parent prelude), the
PMCR registers revert to POR defaults.  The POR default for MT7531
might have MAC_TX_EN=0 on user ports.

On Orbis, `FUN_c85f2250` writes to PMCR for ports 2,3,4 via in-band
management frames.  BUT — this only runs when `softc+0x30e0 != 0`
(carrier polling DISABLED).  In the normal case (carrier polling
enabled, `softc+0x30e0 == 0`), `FUN_c85f2250` is NEVER called —
the gbe:ctrl thread just calls `mts_link_change()` and returns early
(from `FUN_c85f1e80` decompile, lines at 0x85f1e80+).

```c
// From FUN_c85f1e80 (0xffffffffc85f1e80):
if (*(int *)(param_1 + 0x30e0) == 0) {
    // Normal path — no management frames sent
    mts_link_change(param_1);
    return;  // EARLY RETURN, FUN_c85f2250 NOT called
}
// Only when carrier polling DISABLED:
// [poll loop for link]
FUN_c85f2250(parent);  // switch config
```

**So in normal Orbis operation, PMCR is NEVER configured via management
frames.**  The switch ports must be functional from POR defaults or from
the parent driver's HDL/VLAN init.

On Orbis with the original Marvell switch (earlier Baikal revision), the
parent driver's `msk_l2switch_vlan_init` configured switch ports.  On
MT7531 (our revision), this VLAN config is skipped (OUI mismatch), so
the switch relies entirely on POR defaults.

If MT7531 POR defaults have MAC_TX_EN=1, the ports would work without
management config.  If POR defaults have MAC_TX_EN=0, the ports need
explicit enable — and on Orbis, that only happens when carrier polling
is disabled (a debug/non-default mode).

**This means Orbis might ALSO have silent TX on MT7531!**  The vendor
might have tested Ethernet only with the original Marvell switch, not
the MT7531 revision.  Or: the MT7531 POR defaults include TX_EN=1, and
something in our Linux init path clears it (the GPIO reset via parent
prelude?).

## What's left

### Phase 3 TX path — send management frame (25% chance)

If we implement real TX descriptor ring and send one management frame
(ethertype 0xFA42, opcode 0x800B from glm research, to write PMCR for
ports 2-4), we can explicitly enable MAC_TX_EN on switch ports.  The
minimum descriptor format is known (16-byte entries from `mts_init_rings_
kick` analysis).  This is the ONLY software path that can reach switch
core registers from our driver.

### Verify POR defaults (diagnostic only)

Read PMCR values through indirect C45 access if available:
```c
// Can we read switch PMCR via SMI C45?
// MT7531 switch core registers are at different MDIO address than PHY
// Our SMI is hardwired to one PHY address → likely CANNOT read switch core.
```

### Accept hardware limitation

If the switch ports truly need management-frame configuration that only
our TX path can deliver, and we need working TX before the PHY can
transmit, we have a genuine chicken-and-egg problem.  The only resolution
is: implement full TX path to send management frames, hoping that the CPU
port (switch port 5/6 connected to Baikal MAC) doesn't need the same
PMCR configuration as the user ports.

**Distilled recommendation: implement minimum TX path (~100 LOC) to send
one management frame configuring ports 2,3,4 PMCR.  If link comes up
after that, crack a beer.  If not, this problem is genuinely beyond
software-only resolution and requires either sky2-as-shell (which has
working TX/RX from Yukon-2 path) or hardware swap.**

--- deepseek-v41, 2026-05-13
