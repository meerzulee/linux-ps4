# gpt5.5 — v90 MAC link-latch dig — 2026-05-13

## Lead finding

I did not find an Orbis write to BAR+0x208 or BAR+0x210 in the Baikal GBE/MSK/MTS driver paths.  The only Orbis BAR-side software gate I found for the MAC link latch is the parent prelude around BAR+0x11c/0x120, plus normal interrupt unmasking at BAR+0x204/0x54.  Orbis then treats BAR+0x04 bit 0 as pure hardware status: if it is 0, `gbe:phy_ctrl` only restarts PHY autoneg; no Orbis code force-enables a separate MAC link detector later.

That makes the most suspicious missed condition not 0x208/0x210, but whether the Linux standalone driver exactly preserved the parent prelude's B2 clock/interface reset sequence before MTS starts monitoring link.

## BAR+0x208 / BAR+0x210

I scanned the relevant Orbis code ranges:

- parent `if_msk.c` region: 0xffffffffc8510000..0xffffffffc8517000
- child `if_mts.c` region: 0xffffffffc85eb000..0xffffffffc85f3000

No decompiled MMIO expression of the form `*(bar + 0x208)` or `*(bar + 0x210)` appeared.  The only disassembly hits for immediate `0x210` in this range were non-BAR structure offsets, e.g. `FUN_ffffffffc85efdb0` uses `RBX + 0x210` as a kernel object/list field, not `*(softc->bar + 0x210)`:

```
ffffffffc85efe05: LEA R14,[RBX + 0x210]
ffffffffc85f0069: MOV RAX,qword ptr [RBX + 0x210]
ffffffffc85f0085: MOV qword ptr [RBX + 0x210],R13
```

I also did not find a BAR+0x208 immediate in these driver functions.  So the runtime `0x208=1` and `0x210=1` values are likely hardware-owned/status shadows (or set indirectly by a broader reset/enable), not Orbis-programmed link-enable bits.

## The actual Orbis BAR+0x04 link path

`mts_link_change` at 0xffffffffc85eeb90 reads BAR+0x04 and decodes it.  It never writes a latch enable:

```
0xffffffffc85eeb90 mts_link_change
line 12: puVar6 = (uint *)(*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + 4);
line 19: if ((uVar3 & 1) == 0) { uVar4 = 0; }
line 24: uVar5 = uVar3 >> 2 & 3;        // speed field
line 25: uVar4 = ((uVar3 & 0x10) >> 4) * 2 + 1;  // duplex-ish
line 35: uVar4 = uVar3 >> 6 & 4 | uVar4;
```

`mts_intr` at 0xffffffffc85edcf0 calls this only when IRQ status bit 2 is set:

```
line 222: if ((uVar4 & 4) != 0) {
line 223:   mts_link_change(param_1);
line 224:   puVar8 = (uint *)(*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + 4);
line 234:   uVar6 = 0x100;
line 235:   if ((uVar5 & 1) == 0) uVar6 = 1;
line 238:   *(uint *)(param_1 + 0x31c8) |= uVar6; // wake phy_ctrl
```

So Orbis's event chain is: MAC hardware sets BAR+0x04 bit0 and/or IRQ bit2; `mts_intr` reads it; `mts_link_change` reports speed/duplex.  There is no late software latch.

## `gbe:phy_ctrl` confirms BAR+0x04 bit0 is authoritative

The decompiled `gbe:phy_ctrl` body is `FUN_ffffffffc85f0480`.  On event bit 1 it reads BAR+0x04; if bit0 is still down, it only adjusts PHY C22 regs and restarts autoneg:

```
0xffffffffc85f0480
line 119: if ((uVar11 & 1) != 0) {
line 120:   puVar9 = (uint *)(*(long *)(*(long *)(param_1 + 0x3068) + 0x10) + 4);
line 127:   if ((uVar8 & 1) == 0) {
line 129:     mts_smi_cl22_read(param_1,9,&local_40);
line 132:     mts_smi_cl22_read(param_1,4,&local_42);
line 135:     if ((uVar5 & 0x200) == 0) mts_smi_cl22_write(param_1,9,uVar5 | 0x200);
line 138:     if ((uVar4 & 0x180) == 0) mts_smi_cl22_write(param_1,4,uVar4 | 0x180);
line 143:     mts_smi_cl22_write(param_1,0,local_44 | 0x1200);
```

This is important: even when MAC says link down, Orbis does not toggle BAR+0x080..0x0bf, 0x118, 0x128, 0x12c, 0x208, or 0x210.  It only restarts PHY negotiation.

## Parent prelude: the only MAC-side gate I found

`FUN_ffffffffc85131d0(param_1,1)` is called from `msk_init_hw` before `mts_attach/mts_mac_init` paths.  It is the only place I found that looks like a Baikal MAC/link-detector precondition:

```
0xffffffffc85131d0
lines 24-37: BAR+0xf10 = 1; BAR+0xf10 = 2
lines 38-52: BAR+0xf04 = 1; udelay(12000); BAR+0xf04 = 2
lines 104-110: BAR+0x120 = 1
lines 111-124: BAR+0x11c = read16(BAR+0x11c) & 0xf8ff
```

`msk_init_hw` also wraps this with:

```
0xffffffffc8511d50
lines 129-135: BAR+0x04 = 8
line 136:       FUN_ffffffffc85131d0(param_1,1)
lines 171-183: BAR+0x138 = 2; BAR+0x138 = 1
```

If any gate exists for the hardware link monitor, this `0x120=1` plus `0x11c & 0xf8ff` sequence is the only explicit one I found.  It is consistent with Yukon B2 names in Linux `sky2.h`: `B2_CONN_TYP=0x118`, `B2_Y2_CLK_CTRL=0x120`, and `B2_TI_CTRL=0x138`.  The v90 prompt's BAR+0x118 value is therefore probably chip/connection metadata, not a PCS counter.

## BAR+0x080..0x0bf / 0x118 / 0x128 / 0x12c

I found no Orbis MTS writes to BAR+0x080, 0x098, 0x0b0, 0x0b4, 0x118, 0x128, or 0x12c.  The only focus-range MTS write is BAR+0x0ac=9 in `mts_mac_init`:

```
0xffffffffc85ecb60 mts_mac_init
lines 67-73: BAR+0x0ac = 9
```

The only MTS use of BAR+0x09c is in ISR error recovery for IRQ bits 0x500000:

```
0xffffffffc85edcf0 mts_intr
lines 66-90: BAR+0x09c &= ~0x40; BAR+0x09c |= 0x40
```

So I do not think the observed 0x080/0x098/0x0b0/0x0b4 values are deliberate Orbis init writes.  They look like hardware reset/status state or hidden side effects of the broader reset sequence.

## `mts_mac_init` BAR writes we might still need to audit

BAR write order in `mts_mac_init` itself:

1. 0x200 = 0
2. 0x50 = readback ack
3. 0x0ac = 9
4. 0x04 = saved_linkreg & 0x7fffcfff
5. 0x7c = 25000000
6. 0x78 &= ~1
7. 0x14/0x18 = MAC address
8. optional 0x140/0x144 = second MAC
9. 0x0c &= ~0x80
10. 0x74 = 0x2277
11. 0x08 |= 0x07597c00
12. 0x1d4 = 1
13. 0x10 = (old & 0xffffff6e) | 0x81
14. 0x30 = 0x10100
15. multicast filter block at 0x1c4/0x1c8/0x1bc/0x1c0/0x1d0

This does not include 0x208/0x210.

## Recommended next experiment on hardware

Before implementing TX, do one controlled boot that logs BAR+0x11c (16-bit), 0x120, 0x138, 0x208, 0x210 before parent prelude, after parent prelude, after `mts_mac_init`, and after PHY AN complete; if 0x208/0x210 transition exactly with `0x120=1`/`0x138` then they are derived status, not knobs.