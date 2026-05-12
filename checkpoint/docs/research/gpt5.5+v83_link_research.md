# gpt-5.5 — v83 Baikal ethernet link research — 2026-05-12

## Lead finding

I do **not** see a hidden link-enable sequence between `mts_mac_init` and `mts_ifup`.  Orbis brings link up by doing almost all PHY/MAC analog setup **inside `mts_mac_init`** (`0xffffffffc85ecb60`), then `mts_ifup` (`0xffffffffc85ec940`) only re-runs `mts_mac_init`, clears one MAC status/control bit, kicks rings, and resumes the two kthreads.  If v83 still has SMI heartbeat + AN restart but no link, the best next suspect is the **efuse/analog MMD trim block inside `mts_mac_init`**, not a missing post-`mts_mac_init` call.

## What `mts_ifup` actually does

Full decompile of `FUN_c85ec940` is short:

1. Gets child softc via `FUN_c8602ac0()`.
2. Locks `softc+0x30b0` at source line `if_mts.c:0x12e4`.
3. `*(softc+0x32b0) = 0xa000000000000`.
4. Calls `mts_mac_init(softc)`.
5. Clears bit 6 at parent BAR-derived `(**(softc+0x30a0) + 0x1c8)`:
   `*(BAR+0x1c8) &= 0xffffffbf`.
6. Calls `mts_init_rings_kick(parent)`.
7. Resumes `gbe:ctrl` kthread, sets event `softc+0x3178 = 0x10000`, wakes it.
8. If carrier polling enabled (`softc+0x30e0 == 0`), resumes `gbe:phy_ctrl`, sets event `softc+0x31c8 = 0x10100`, wakes it.

No direct SMI writes appear in `mts_ifup` except through `mts_mac_init` and later kthread events.  No extra MT7531 init helper is called between `mts_mac_init` and `mts_ifup`.

## What the kthreads add after `ifup`

`gbe:ctrl` body `FUN_c85f0190` handles event `0x10000` by calling `FUN_c85f1e80`.  That function mostly:

- calls `mts_init_rings_kick()` again;
- calls `mts_link_change()` if `softc+0x30e0 == 0`;
- clears BAR+0x54 bit 12 (`&= 0xffffefff`) around source line `if_mts.c:0x11bf`.

`gbe:phy_ctrl` body `FUN_c85f0480` handles event `0x10100` as already found:

- event `0x100`: read C45 `0xa2001e` twice, then poll C22 BMSR reg 1 up to `0x4e84` iterations with short sleeps; on timeout, set C22 reg 9 bit `0x200`, then BMCR `|=0x1200`.
- event `0x1`: read BAR+0x04.  If bit 0 is clear, read C22 regs 9 and 4, set reg 9 bit `0x200`, set reg 4 bits `0x0180` if both absent, then BMCR `|=0x1200`.

So v83’s AN-restart mirror is the real post-ifup link action.  I found no additional vendor-MMD write in the kthread body except the C45 read of `0xa2001e`.

## Linkreg bit 0 is passive, not explicitly set by Orbis

`mts_link_change` (`0xffffffffc85eeb90`) only reads BAR+0x04 and maps it to an ifmedia/link-state word passed to `FUN_c852c500`.  Decode from decompile:

- BAR+0x04 bit 0: link up/down.
- bits 2..3: speed (`00`=10, `01`=100, `10`=1000).
- bit 4: full duplex.
- bit 6: flow-control indication.
- bit 8: secondary/aux state used in the dual-port path.

`mts_intr` (`0xffffffffc85edcf0`) calls `mts_link_change()` when IRQ status bit `0x4` is set, then reads BAR+0x04 again.  It does not force bit 0.  The only `mts_mac_init` write near BAR+0x04 that matters preserves the read value except clearing upper control bits (`uVar6 & 0x7fffcfff` around `mts_mac_init` decompile lines 260-265).  I found no BAR+0x04 write that sets bit 0.  Therefore linkreg bit 0 is almost certainly asserted by MAC silicon from PHY/RGMII/SGMII-side signaling, not software.

## MT7531/vendor init inside `mts_mac_init`

`mts_mac_init` contains the important missing class of work.  Before normal MAC register setup, it performs a large vendor-MMD and paged-C22 sequence:

Efuse/trim-gated block, guarded by `FUN_c8764760(0x6c) & 0x80800000 == 0x80800000`:

- C45 write `0xe0001e = (efuse[0x68] & 0x3f) << 8`.
- C45 write `0x115001f = (efuse[0x68] >> 6) & 7`.
- Repeated read/modify/write of C45 `0x174001e`, `0x175001e`, `0x172001e`, `0x173001e` using lookup table `DAT_c8b59a80` and efuse offsets `0x5c`, `0x60`, `0x64`.
- C45 writes `0x120001e`, `0x160001e`, `0x170001e`, `0x180001e`, `0x190001e`, `0x200001e`, `0x210001e`, `0x220001e` with values derived from efuse trims.
- Fixed/toggle writes: `0x960001e=0x8000`, `0x370001e=0x33`, clear bits in `0x390001e`, clear bit `0x1000` in `0x107001f`, set then clear bits around `0x171001e`/`0x390001e` with a `udelay(0x32)`.

Unconditional tail after the guarded block:

- `mts_smi_cl45_write(0x189001e, 0x110)`.
- Several token-ring style C22 page `0x52b5` writes via regs 0x10/0x11/0x12, including `(0x11,0xb90a),(0x12,0x006f),(0x10,0x8f82)` and `(0x11,0xbaef),(0x12,0x002e),(0x10,0x968c)`.
- page 3 reg 0x1c = `0x0c92`, then page 0.
- BAR+0x7c = `25000000`.
- C45 `0x122001e = 0xffff`.
- More page `0x52b5` token writes: `(0x11,0x704d),(0x12,0),(0x10,0x9698)`, `(0x11,0x344f),(0x12,2),(0x10,0x969a)`, C45 `0x268001f=0x07f4`, then `(0x11,4),(0x12,0),(0x10,0x9686)`, `(0x11,0x0671),(0x12,6),(0x10,0x8fae)`.
- C22 ANAR reg 4 is finally masked: `reg4 &= 0xf3ff`, then BMCR is restarted later with `BMCR |= 0x1200`.
- C45 `0x3c0007=0`, read/clear bit `0x1000` in `0x33001e`.

This overlaps conceptually with mainline `drivers/net/phy/mediatek/mtk-ge.c` `mt7531_phy_config_init`: both program MT7531 vendor MMD 0x1e/0x1f and token-ring-ish analog trim paths, but Orbis uses Sony efuse values and a much larger sequence.  I did **not** see DSA-style switch VLAN setup in `mts_*`; this looks like PHY/analog/link training trim, not switch fabric configuration.

## Recommended next experiment on hardware

If v83 AN restart still leaves BMSR bit 2 low, add/log the missing `mts_mac_init` PHY trim subset: at minimum execute the unconditional tail above plus mainline MT7531 `mt7531_phy_config_init` equivalents, and separately test whether the efuse-guarded block is being skipped in Linux because the Sony efuse reads are absent.