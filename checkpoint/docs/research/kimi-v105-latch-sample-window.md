# v105 — When does the MAC sample link? The init-moment hypothesis

**kimi-k2.6, 2026-05-13**

## Hermes finding

No Orbis function ever rewrites `BAR+0x008`, `0x010`, or `0x07c` after `mts_mac_init`. There is **no late resync path**. If the latch can be re-triggered, it must happen during the init sequence itself.

## Revised hypothesis: latch samples PHY MII exactly once during `mts_mac_init`

Given:
- v91 (probe-only, no ndo_open): bit 0 was **set** at boot
- v97+ (probe + ndo_open): bit 0 is **always 0**
- v104 (empty ring restart): bit 0 still **0**
- `mts_mac_init` is the only function that writes `BAR+0x008/0x010/0x07c`

The most parsimonious explanation is that the MAC samples the PHY MII "link" signal **exactly once** during `mts_mac_init`, stores it in a sticky register, and never re-evaluates. This is common in low-cost MAC designs to avoid continuous PCS polling.

| Boot | `mts_mac_init` timing | PHY state at that moment | Latch result |
|---|---|---|---|
| v91 | Early probe | PHY already linked (bootloader) | **1** |
| v97+ | Early probe | PHY still training / AN incomplete | **0** |
| v104 | After empty-ring restart | PHY linked, but `mts_mac_init` already passed | **0** (sticky) |

## Why every post-init trick fails

- AN restart (v103): PHY changes state, but MAC already latched "down"
- Master reset (v97 live): Resets datapath, not the sticky link latch
- Empty ring (v104): Resets engine, not the latch
- MAC_CTRL3 toggle: Orbis never does this; the latch is not in that control path

## What would actually work

**(a) Move `mts_mac_init` to run AFTER PHY link is stable.**

In `ndo_open`:
1. Wait for kthread to report `BMSR bit 2 = 1` (or poll directly)
2. Only THEN call `mts_mac_init()`
3. The MAC samples PHY MII while link is genuinely up → bit 0 latches → TX gate opens

This is **Option A** from v103. The risk is substantial reorder, but the theory is now strongly supported.

## Alternative: is it truly once per power cycle?

If the above fails, the latch is **write-once per power cycle** and the only path is a cold boot with PHY already linked before `mts_mac_init` runs. That would mean v91 was a bootloader artifact we cannot recreate.
