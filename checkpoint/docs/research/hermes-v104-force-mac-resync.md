# Hermes (gpt-5.5) — v104 force MAC resync — 2026-05-13

Finding: I do not find an Orbis “force BAR+0x04 bit0” or post-open MAC resync sequence touching `BAR+0x008`, `BAR+0x010`, or `BAR+0x07c`.  In the decompiled MTS corpus available here, those three offsets are setup-only writes in `mts_mac_init`:

- `BAR+0x07c = 25000000` after PHY page/TR writes (`/tmp/mts_mac_init.c:224-226`).
- `BAR+0x008 |= 0x07597c00` (`/tmp/mts_mac_init.c:344-350`).
- `BAR+0x010 = (old & 0xffffff6e) | 0x81` (`/tmp/mts_mac_init.c:364-370`).

Searches across the saved Orbis decompiles for later BAR patterns found no `mts_intr`, `mts_link_change`, `gbe:phy_ctrl`, TX, RX, or ring-init path writing these offsets after initial setup.  `mts_link_change` only reads `BAR+0x04` and decodes bit0/speed/duplex/media (`/tmp/mts_link_change.c:12-68`).  `gbe:phy_ctrl` retries by PHY C22/C45 reads/writes and BMCR AN restart, not MAC control resampling (`/tmp/mts_phy_ctrl.c:78-147`).  `mts_init_rings_kick` only writes ring bases, engine starts, IRQ mask, and `0x1c8` gate (`/tmp/v93-ghidra/mts_init_rings_kick.c:59-123`).

So if there is a resample trigger, it is likely the initial `mts_mac_init` sequencing itself, not a separate late rearm.  The most plausible experiment is to replay only the harmless MAC-side tail after RX prefill/open: `0x07c=25000000`, `0x78&=~1`, `0x08|=0x07597c00`, `0x10=(old&0xffffff6e)|0x81`, `0x30=0x10100`, then read `0x04/0x50/0x6c`.  This is not an Orbis late path; it is forcing the one-shot setup edge again.
