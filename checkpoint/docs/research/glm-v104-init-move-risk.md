# v104: Risk analysis — moving mts_parent_prelude and mts_mac_init from probe to ndo_open

## Current probe order (lines 1812-1917)

```
mts_parent_prelude(mts);   // BAR+0xf04 reset, BAR+0x060/064/068/06c init, BAR+0x158 PHY clock
mts_mac_init(mts);          // MAC reset, CTRL1-3, MODE, PAUSE, RX_GATE, CLK, INIT_AC, IRQ block
writel(TX/RX ring DMAs)    // BAR+0x3c/0x44/0x40/0x48
writel(RX_KICK | START)    // engine enable
writel(0xe80 = 1,2,8)      // status unit (no-op on Baikal — 0xe8x range absent)
mts_phy_init(mts)           // SMI/PHY register setup
timer + kthread + register_netdev
```

## What moving init to ndo_open would mean

In Orbis, `mts_mac_init` is called inside `mts_ifup` (the open path). The
Orbis probe only does PCI enable + BAR map. Actual MAC/PHY bring-up is
deferred to ifconfig up. This means: in Orbis, the MAC is fresh during
open, and the link-status latch sees the PCS/RGMII transition after the
register writes complete.

Moving our init from probe → ndo_open:

| Step | Probe (current) | ndo_open (proposed) | Risk |
|---|---|---|---|
| pci_enable, iomap, DMA rings | probe | probe (stays) | none |
| ISR registration | probe | probe (stays) | none — ISR must exist before open |
| mts_parent_prelude | probe | **ndo_open** | LOW — switch GPIO + PHY clock, no state carried across |
| mts_mac_init (MAC reset + CTRL) | probe | **ndo_open** | LOW — resets MAC fully, clean slate each open |
| Ring DMA writes + engine enable | probe | **ndo_open** | LOW — rings pre-allocated, just write addresses |
| mts_phy_init | probe | **ndo_open** | **MEDIUM** — PHY registers survive MAC reset on Orbis but need testing |
| v82-v89 PHY tweaks (EEE, AN) | probe | **ndo_open** | **MEDIUM** — depends on PHY state surviving MAC reset |

## Key risk: PHY register persistence

PHY registers (0x00-0x1F via SMI) are in the external RTL8211, connected
through the SMI bus. MAC reset (`BAR+0x000 = 0`) does NOT reset the PHY.
So PHY settings written by v82-v89 will persist across MAC reset.

BUT: `mts_parent_prelude` does `BAR+0x158` RMW (PHY clock select) and
`BAR+0xf04 = 1,2` (switch chip GPIO toggle). The switch chip reset WILL
drop and re-establish the SGMII link between switch and PHY. This means
PHY AN state WILL flap when prelude re-runs. That's actually desirable —
it's the same sequence Orbis uses.

## The real risk

**Power-on MAC state vs. after-probe MAC state**: Currently probe runs all
init once. If we move to ndo_open, `mts_mac_init` runs on every `ip link
set up`. If there's register state that persists from a previous `ip link
set down` that breaks the re-init path, we get a bug. The MAC reset
(`BAR+0x000 = 0`) should clear all internal state, but the 0x060-0x06c
registers in `mts_parent_prelude` are switch-side, not MAC-side. Writing
0x060/0x064/0x068 again on re-open should be safe (idempotent). The
0xf04 reset-resequence (1 → msleep → 2) is also idempotent (switch chip
reinitializes each time).

## Verdict

Moving `mts_parent_prelude` + `mts_mac_init` to ndo_open is **low risk**.
PHY registers survive MAC reset. Switch chip re-probe is intentional.
The v82-v89 PHY tuning (EEE disable, AN settings) happens in
`mts_phy_init` which would also move to ndo_open — they re-run each open
which is correct.

**One gotcha**: the ISR was registered in probe. If ndo_open re-does
MAC reset, any in-flight IRQ from a previous open path could race. Mitigate
with `synchronize_irq(mts->irq)` at start of ndo_open, before writes begin.

## Why this could fix the latch

The link-status latch at BAR+0x04 bit 0 is one-shot edge-triggered.
In v91 (the boot where it DID fire), MAC init happened before any RX
ring was written. In v97+, the RX prefill in ndo_open clobbers whatever
transient state makes the latch fire. By moving full MAC init to ndo_open,
the latch window opens fresh when `ip link set up` runs — exactly when
we want it, with no preceding RX ring writes to disturb the MAC's
internal state machine.