# v102 — Link-latch timing: one-shot vs RX-busy hypothesis

**kimi-k2.6, 2026-05-13**

## Core finding

All agents converge: **BAR+0x06c bit 9 is read-only HW status**, set when the MAC internally declares "link up." It is not a gate we can write.

The critical behavioral delta is:
- **v91** (dummy RX, no real descriptors): link bit 0 latches, `LINK_CHANGE` IRQ (bit 2) fires.
- **v97** (real RX descriptors, NAPI active): link bit 0 **never** latches, bit 2 IRQ **never** fires.

## Hypothesis: link assessment is one-shot and RX-busy blocks it

Many MACs perform link-state sampling only during **RX idle periods** or at the end of a descriptor poll cycle. If real RX descriptors keep the RX engine perpetually busy (ownership bit 31 toggling, NAPI consuming), the MAC may skip its periodic "check PHY MII status" pass. In v91, the RX engine was effectively idle (dummy ring, no NAPI), so the MAC sampled PHY state early and latched link.

If the link-latch is **one-shot** (set once after MAC init, then ignored), v97’s `ndo_open` — which starts real RX and TX — arrives **after** the one-shot window has already expired. The MAC already decided "no link" during probe, and with the RX engine now busy, it never revisits that decision.

## Two recovery paths

1. **Move AN restart to after `ndo_open`**:
   - Trigger a fresh PHY auto-negotiation pulse **after** the netdev is up and RX engine is running.
   - The MAC may see a new PHY link-change event and re-arm its one-shot latch.
   - This mirrors Orbis behavior: `mts_mac_init` runs inside `mts_ifup` (open path), not at probe.

2. **Force MAC re-sample via `MAC_CTRL3`**:
   - `MAC_CTRL3` (`BAR+0x010`) controls MAC operating mode. If a "link resample" or "PCS restart" bit exists (e.g., bit 5 or bit 12), toggling it could force the MAC to re-evaluate PHY state without requiring an AN restart.
   - Safer than AN restart because it does not disturb the PHY.

## Recommended test

1. In `ndo_open`, after starting RX/TX engines, **write `MAC_CTRL3 |= (1 << N)`** for candidate bits 5, 12, or 15, then read `BAR+0x004`.
2. If no latch: trigger **AN restart** from `ndo_open` (not probe), wait 2 s, read `BAR+0x004`.
3. If either succeeds, the one-shot timing hypothesis is confirmed.
