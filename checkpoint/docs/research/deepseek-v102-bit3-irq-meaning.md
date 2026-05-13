# deepseek-v102-bit3-irq-meaning.md — 2026-05-13

## Bit 3 (0x8) = RX symbol activity / GMII energy detect

From Orbis `mts_intr` (`0xffffffffc85edcf0`) — bit 3 is NOT handled by any
specific branch in the ISR.  It falls through to default W1C-ack.  The Orbis
mask 0x7bfffe HAS bit 3 enabled, so Orbis expects it.

Bit 3 fires alongside bit 18 (secondary state transition) in your 0x00040008
pattern.  When the partner RTL8153 went link-down then link-up, the PHY
re-started AN, generating GMII/RGMII signal activity.  The MAC sees symbols
on its RX interface → raises bit 3 (activity detected) + bit 18 (internal
state changed).  **Bit 2 (LINK_CHANGE) does NOT fire because BAR+0x04 bit 0
never transitions 0→1.**  The MAC's link-change ISR is edge-triggered on the
link-up status bit — without link-up, there's no edge.

This is consistent with all evidence: the MAC receives PHY symbols (counters
at 0x118/0x128/0x12c increment), decodes speed/duplex (linkreg=0xb18 shows
1000M), but BAR+0x04 bit 0 hardware latch refuses to assert.  Bit 3/18 firing
on partner link transition is the expected behavior for a MAC that sees PHY
activity but can't declare link-up.

## What this means for TX

TX engine dead, bit 2 never fires, bit 3+18 fire on PHY activity — all
three point to the MAC being in a "monitor but don't commit" state.  The
chicken-and-egg breaks when the TX engine can fetch descriptors AND the
MAC can assert link-up.  Fix TX first (BAR+0x138 = 2→1), link-up may follow.

--- deepseek-v41, 2026-05-13
