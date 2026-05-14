# Hermes (gpt-5.5) — v106 why MAC-init failed — 2026-05-13

Q1: re-reading `mts_ifup` line-by-line, I do not see a missed step between `mts_mac_init` and ring start.  The exact Orbis order is:

1. `softc+0x32b0 = 0xa000000000000`
2. `mts_mac_init(lVar4)`
3. `BAR+0x1c8 &= ~0x40`
4. `mts_init_rings_kick(...)`
5. resume `gbe:ctrl`, wake RX event, resume/wake `gbe:phy_ctrl`

Source: `/tmp/mts_ifup.c:12-57`.  Therefore `0x1c8[6]` clear is definitely AFTER `mts_mac_init`, not before.  v105 failed because my earlier “open-time mac_init opens the latch window” was incomplete: Orbis does not rely on mac_init alone to create link; it calls mac_init while the parent/MSK/L2-switch state already exists and while its `gbe:phy_ctrl`/interrupt state machine is arranged differently.  A naked replay of MTS MAC tail in Linux can leave the hardware in the same decoded state (`0xb18`) without producing the missing internal bit0 edge.

Q2: if v106 also fails, I would classify BAR+0x04[0] as hardware/parent-state-only, not software-forced by MTS.  The specific Orbis sequence still not fully replicated is before child open: parent `baikal_gbe_attach`/`msk_init_hw` and helper `FUN_c85131d0` run L2-switch reset/init sequences, including repeated `BAR+0xf04 = 1`, delay, `BAR+0xf04 = 2`, retry loops, and parent-side register writes (`/tmp/v90_msk_init_hw.c:374-404`, `/tmp/v90_FUN_ffffffffc85131d0_5131d0.c:38-49`).  Those are not `BAR+0x000/0x002`; on the child MTS BAR, `0x000` is SMI, and `mts_mac_init` reset is `BAR+0x200=0` (`/tmp/mts_mac_init.c:39-45`).

Next experiment: if v106 tests anything, test the parent/L2 `0xf04 1→2` reset/init sequence plus `mts_mac_init`, not `0x1c8` reordering or child `0x000/0x002` pokes.
