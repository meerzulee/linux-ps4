# v104 — Re-arming the one-shot link latch

**kimi-k2.6, 2026-05-13**

## What we know

The MAC bit-0 latch fired exactly once in v91 (empty RX ring, probe-only) and **never again** despite:
- PHY AN restart from `ndo_open` (v103)
- `BAR+0x200` master reset pulse (v97 live)
- Host link partner flap (v97 live)
- `BAR+0x1c8` bit 6 toggle (v97 live)

This proves the latch is **not** re-armed by PHY-level events, MAC resets, or IRQ mask manipulation.

## Chip-design inference

The latch is evaluated during a **single transition window** inside the MAC's RX-engine state machine: the moment the engine moves from `STOPPED` to `RUNNING`. If descriptors are already valid at that transition, the scheduler immediately enters "packet processing" mode and **skips link sampling** permanently. In v91, the ring was empty, so the scheduler had no work, sampled PHY MII, and latched link.

This is common in dual-path MACs: the RX datapath and link-monitor share a state machine. Once datapath work is present, the monitor is deprioritized and never scheduled again.

## What this means for re-arming

**(a) MAC reset, (b) clock toggle, (c) MAC_CTRL3 toggle** are all insufficient because they do not reset the RX-engine state machine deeply enough. The MAC remembers it has "committed to datapath mode."

The only way to re-open the latch window is to **recreate the cold-start sequence**: stop the RX engine, discard all descriptors, and restart it while the ring is empty — then populate descriptors only after link latches.

## Practical path forward

**Option C from v103**: In `ndo_open`, start the RX engine with **invalid/empty descriptors** (or a single dummy descriptor), wait for `LINK_CHANGE` IRQ and bit-0 latch, then hot-swap to the real descriptor ring. This mirrors the v91 timing exactly.

If this fails, the latch is truly write-once-per-power-cycle and the only remaining option is moving all MAC init to `ndo_open` (Option A), ensuring the RX engine is never started before the PHY link is stable.
