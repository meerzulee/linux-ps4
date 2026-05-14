# v106 — Why the latch rejected mts_mac_init re-run

**kimi-k2.6, 2026-05-13**

## The theory failed: bit 0 stayed 0 even with PHY linked during mac_init

If the latch sampled PHY MII during `mts_mac_init`, it should have seen `BMSR=0x7969` and set. It did not. Therefore the latch is **not** sampling the PHY MII link signal at the moment `mts_mac_init` runs.

## Revised hypothesis: latch triggers on **master reset release**

Many MACs sample link exactly once — during the transition from **reset-asserted** to **reset-released**. The `BAR+0x200` master reset is not just a datapath reset; it is the state-machine bootstrap point.

- **v91**: Bootloader may have left `BAR+0x200 = 1` (asserted). Our `writel(0, 0x200)` performed the **release**, triggering the one-shot sample. PHY was already linked → bit 0 latched.
- **v97+**: POR or previous boot left `BAR+0x200 = 0`. Writing `0` again is a no-op. The sample window never opened.
- **v105**: Same problem — `0x200` was already `0` when `mts_mac_init` re-ran in `ndo_open`. No release edge, no sample.

This explains every observation perfectly.

## Alternative: the latch samples RGMII clock stability, not PHY MII

Another chip-design pattern: the MAC declares "link up" only when it detects **stable RX clock** from the PHY, not the MDIO link bit. In v91, the RX engine was not yet running, so the MAC could observe the clock as "present but idle." In v97+, the busy RX datapath might mask the stability check. But this is less parsimonious because RX works (clock is clearly stable).

## Final test: reset-release cycle in ndo_open

For v106:
1. Confirm PHY is linked (`BMSR=0x7969`)
2. In `ndo_open`: write `1` to `BAR+0x200`, wait 10 µs, write `0`
3. Run `mts_mac_init` tail (0x008, 0x010, 0x07c, 0x078, 0x030)
4. Read `BAR+0x004`

If bit 0 sets, the reset-release hypothesis is confirmed.

## If v106 fails

Then the latch is likely **write-once per power cycle** with the sample window tied to a **pre-bootloader condition** we cannot replicate. At that point the honest answer is:

> The MAC link-latch is irreversibly committed to "down" after POR. Only a cold boot with PHY pre-linked before bootloader touches `BAR+0x200` can satisfy it. All software re-arm paths are exhausted.

One remaining untested corner: a **full power-cycle** with the driver built as a module and loaded only after PHY is confirmed linked (skip probe-time `mts_mac_init` entirely, do everything from `insmod`). But on PS4 this is impractical without a normal boot loader.
