# Hermes (gpt-5.5) — v102 MAC link-bit source — 2026-05-13

Finding: Orbis does not explicitly set `BAR+0x06c[9]` on link-up, and `mts_intr`/`mts_link_change` do not contain a hidden “TX enable after link” BAR sequence in the decompile I can verify.

The link-change IRQ path is read/notify only.  In `mts_intr`, when status bit 2 fires, Orbis calls `mts_link_change(param_1)`, then reads `BAR+0x04`, then wakes `gbe:phy_ctrl` with event `0x100` if bit0 is set, else event `1` (`/tmp/v93-ghidra/mts_intr.c:222-239`).  No write to `0x06c`, `0x34`, `0x38`, MAC_CTRL, or MAC_MODE occurs in that branch.  Prior notes also say `gbe:phy_ctrl` handles those events by polling MMD/C22 BMSR and optionally restarting AN (`BMCR |= 0x1200`), not by programming MAC TX clocks.

So `BAR+0x04[0]` is the primary hardware condition, and `0x06c[9]` is likely downstream status: TX scheduler/clock ready only after the MAC declares link up.  The latch condition is probably not “RX packet received” (RX now works with `0xb18`), but MAC-side PCS/RGMII link synchronization: PHY AN complete plus the MAC seeing a stable PHY-to-MAC link indication at the selected speed/duplex.  Orbis uses `0xb19` as already-hardware-latched state; it does not manufacture it.

Most relevant software prerequisites remain the `mts_mac_init` values that feed that detector: `MAC_CTRL1 |= 0x07597c00`, `MAC_CTRL2 &= ~0x80`, `MAC_CTRL3 = (old & 0xffffff6e)|0x81`, `MAC_MODE=0x10100`, `MAC_PAUSE=0x2277`, `RX_GATE &= ~1`, `MAC_CLK=25MHz` (`ps4_mts.c:489-505`).  Since v91 had `0xb19` and v93+ does not, diff the final live values of `0x08/0x0c/0x10/0x30/0x74/0x78/0x7c` and PHY MMD/C22 link/EEE/clock regs between those boots.  The regression is likely an ordering/state side effect of RX prefill/open, not a missing link-up ISR write.
