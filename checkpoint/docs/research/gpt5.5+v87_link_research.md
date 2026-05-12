# gpt5.5 v87 link research — 2026-05-13

Lead finding: I do not see any Orbis post-`mts_mac_init` magic that enables the PHY's physical link signal.  The only post-ifup actions are ring/IRQ plumbing, passive link reads, and in-band management reads/resets for switch ports 2/3/4.  For BMSR bit 2 staying low after AN-complete, the Ghidra evidence points away from a missing MAC-side force-link bit and toward PHY-side negotiation/mode configuration: Orbis never checks M/S fault reg 10, never writes C45 MMD 1/3 PMA/PCS controls, and never programs the MT7531-standard RGMII/SGMII mode registers that mainline mt7530 uses.

## Q1: PMA/PCS enable: no MMD 1 or MMD 3 access found

I re-decompiled `mts_mac_init` (`0xffffffffc85ecb60`), `mts_ifup` (`0xffffffffc85ec940`), `gbe:phy_ctrl` (`0xffffffffc85f0480`), and all xrefs to `mts_smi_cl45_read/write` (`0xffffffffc85ee640` / `0xffffffffc85ee490`).  The C45 helper encodes `param2` as: MMD = low 5 bits, reg = high 16 bits.

All `mts_*` C45 accesses decode to MMDs `0x1e`, `0x1f`, and one `0x07`; none target standard PMA/PMD MMD 1 or PCS MMD 3.  Examples:

- `mts_mac_init+0x140-ish`: `mts_smi_cl45_write(sc, 0xe0001e, ...)` => MMD `0x1e`, reg `0x00e0`.
- `mts_mac_init`: `0x115001f` => MMD `0x1f`, reg `0x0115`.
- tail: `0x189001e`, `0x122001e`, `0x268001f`, `0x33001e`.
- `mts_mac_init` line with `mts_smi_cl45_write(sc, 0x3c0007, 0)` => MMD `0x07`, reg `0x003c`.
- `gbe:phy_ctrl` only reads `0xa2001e` twice => MMD `0x1e`, reg `0x00a2`.

Conclusion: if MT7531 needs PMA_CONTROL_1 or PCS_CONTROL_1 unpower/unreset writes, Orbis is not doing them through `if_mts.c` C45.  They must be strap/firmware defaults, switch-internal, or not used in this mode.

## Q2: Master/slave: Orbis does not inspect reg 10; reg 9 is only OR-preserved

`gbe:phy_ctrl` (`0xffffffffc85f0480`) event `0x100` and event `0x1` only ensure 1000BASE-T advert bit 9 is set in C22 reg 9:

```c
mts_smi_cl22_read(sc, 9, &local_3c);
if ((local_3c & 0x200) == 0) local_3c |= 0x200;
mts_smi_cl22_write(sc, 9, local_3c);
...
mts_smi_cl22_read(sc, 0, &bmcr);
mts_smi_cl22_write(sc, 0, bmcr | 0x1200);
```

The same pattern appears in event `0x1`: read reg 9, write `reg9 | 0x200` if absent; read reg 4 and possibly OR `0x0180`; restart AN.  I found no read of C22 reg 10 in `mts_mac_init`, `mts_ifup`, `gbe:phy_ctrl`, or `gbe:ctrl`.

There is ifmedia/ioctl code at `FUN_c85ef7d0` / `FUN_c85f0e50` that can rewrite reg 4, reg 9, and BMCR for user-selected modes, but that is control-plane media setting, not default link bring-up.  Default Orbis bring-up preserves any existing master/slave bits 11-12 in reg 9; it does not force master/slave.

Implication for v87: clearing reg9 bit 9 and/or stopping 1000 advertisement is not something Orbis does by default, but it is well motivated by v86's `reg10=0x3c00` M/S fault.  Orbis provides no hidden correction path for that fault.

## Q3/Q4: RGMII/SGMII timing or mode select: not in post-ifup path

I found no post-`mts_mac_init` C45 write that resembles mainline MT7531 mode setup (`MT7531_CLKGEN_CTRL 0x7500`, `MT753X_MTRAP 0x7804`, `TOP_SIG_SR 0x780c`, SGMII base `0x5000/0x6000`, or PHY VEND1 regs 0x13/0x14).  `mts_ifup` decompile is minimal:

```c
mts_mac_init(sc);
*(BAR+0x1c8) &= 0xffffffbf;
mts_init_rings_kick(parent);
kthread_resume(gbe:ctrl); event=0x10000;
kthread_resume(gbe:phy_ctrl); event=0x10100;
```

Inside `mts_mac_init`, Orbis has large MMD `0x1e/0x1f` trim blocks and C22 page `0x52b5` token writes, but no access to the mainline MT7531 switch global registers that choose RGMII/SGMII host-port mode.  The most mode-looking MAC-side writes are:

- BAR+0x7c = `25000000` (25 MHz ref clock)
- BAR+0x30 = `0x10100` (MAC mode)
- BAR+0x08 OR `0x07597c00`
- BAR+0x10 = `(old & 0xffffff6e) | 0x81`
- BAR+0x04 = `old & 0x7fffcfff` twice; this clears bits 12-13 and 8-9, but never sets bit 0.

So if Baikal needs an MT7531 host-port interface-mode write, it is not in the visible Orbis `mts_*` C45 path.  Either firmware/straps already configure it on Orbis, or the interface is not standard MT7531 DSA host-port mode.

## Q5: in-band switch management is real, but appears to manage switch ports 2/3/4, not the host PHY link

`FUN_c85f2250` (`gbe:ctrl` helper) does more than prior notes said:

```c
FUN_c85f11c0(sc, 2, 0x13);
FUN_c85f11c0(sc, 3, 0x13);
FUN_c85f11c0(sc, 4, 0x13);
... send ethertype 0xfa42 payload cmd 0x800b ...
... send ethertype 0xfa42 payload cmd 0x600b ...
if (ok && (response & 1)) print "L2 switch has been reset."
FUN_c85f1010(parent);
```

`FUN_c85f11c0` builds 32-byte frames with ethertype `0xfa42`, opcode byte `0x0f`, command words `0x9807`, polling `0x980b`, final read `0x990b`; it addresses `port << 5 | reg`.  `FUN_c85f1010` then reads ports 3, 2, 4 regs `0x11` and `0x00`, decodes link/speed/duplex bits, and publishes aggregate link state through `FUN_c852c500`.

This is switch-management/status for ports 2/3/4.  It may be required for Orbis's multiport/secondary-MAC reporting, but I do not see it configuring the host port before PHY link.  It reads status after reset; it does not write a host-port PMCR/force-link equivalent.

## Q6: no force-link mechanism found

`mts_link_change` (`0xffffffffc85eeb90`) is read-only on BAR+0x04: bit 0 link, bits 2-3 speed, bit 4 duplex, bit 6 flow, bit 8 aux.  `mts_intr` (`0xffffffffc85edcf0`) calls `mts_link_change` on IRQ status bit 2/`0x4`, then reads BAR+0x04 again; it does not set link.  The only BAR+0x04 writes I found are in `mts_mac_init`, and both mask bits off (`old & 0x7fffcfff`), never set bit 0.

## Recommended hardware direction

Test v87 H1/H2 exactly: stop advertising 1000BT and stop periodic AN restart.  If link still stays down with reg10 fault gone, the next RE-grounded experiment is not in-band frames; it is to compare current MT7531 switch global/host-port strap registers (`0x7804`, `0x780c`, `0x7500`, PMCR port 5/6) against a known-good Orbis state, because Orbis `if_mts.c` does not program them visibly.