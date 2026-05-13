# Hermes (gpt-5.5) — v105 MAC init relocation — 2026-05-13

Q1: yes, if Orbis has a software-visible bit0 latch sampling moment, it is inside `mts_mac_init`, not inside the empty-ring/engine-start window.  `mts_ifup` order is explicit: acquire open lock, set `softc+0x32b0`, call `mts_mac_init(lVar4)`, clear `BAR+0x1c8[6]`, call `mts_init_rings_kick`, then resume `gbe:ctrl` / `gbe:phy_ctrl` (`/tmp/mts_ifup.c:12-57`).  That means Orbis expects MAC link detection to be armed before descriptor engines are started.

The suspicious `mts_mac_init` sequence includes an actual write to `BAR+0x04`: it reads link/status, later writes `uVar6 & 0x7fffcfff` back to `BAR+0x04` (`/tmp/mts_mac_init.c:201-204,260-266`), then clears `0x78[0]`, programs clock `0x7c=25000000`, pause `0x74=0x2277`, `MAC_CTRL1 |= 0x07597c00`, `0x1d4=1`, `MAC_CTRL3=(old&0xffffff6e)|0x81`, and `MAC_MODE=0x10100` (`/tmp/mts_mac_init.c:267-379`).  The latch trigger is most likely this whole MAC tail, not a single later poll.

Q2: v105 should move/replay `mts_mac_init` into `ndo_open`, but match Orbis order: run it before ring base programming/engine start, not after empty-ring engine start.  Parent prelude is less clear: Orbis parent attach does parent init before child/open; I would keep it in probe unless v105 deliberately tests a full fresh-open sequence, then run prelude immediately before `mts_mac_init` and log all readbacks.

Q3: I find no explicit `BAR+0x04[0]` poll-with-timeout in `mts_attach` or `mts_ifup`.  `mts_attach` calls `mts_mac_init` once during resource setup (`/tmp/v93-ghidra/mts_attach.c:163-165`), while `mts_ifup` calls it again at open.  Link waiting is deferred to `gbe:phy_ctrl`, which polls PHY BMSR, not MAC bit0.
