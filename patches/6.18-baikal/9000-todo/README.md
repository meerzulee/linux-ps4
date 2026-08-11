# 6.x-baikal: Outstanding TODO

## MT7668 WiFi/BT (mt76x8 vendor driver)

The 5.4-baikal stack carries an entire vendor MediaTek mt76x8 driver tree
(~250 files, ~214k lines) covering the MT7668 chipset that ships in
Baikal-revision PS4s. **None of the 6.x reference trees we surveyed
(crashniels-6.15-baikal, feeRnt-6.15.4-baikal-crashniels,
feeRnt-6.15.4-BaikalLove) include this driver.**

That means a 6.x-baikal kernel built from the patches in this directory
will boot on a Baikal PS4 but will not bring up WiFi/BT. The 5.4 build
remains the WiFi-capable baseline until this is addressed.

### Why not just port mt76x8 forward?

Because:

1. The 5.4 mt76x8 driver hard-depends on 5.4-era networking APIs
   (NAPI, cfg80211, mac80211 interfaces). Forward-porting will require
   non-trivial API adaptation.
2. The driver is a Sony/MediaTek vendor codebase, not upstream.
   Mainline `mt76` doesn't support the 7668 part.
3. We want to land a working 6.x baseline FIRST and tackle WiFi as a
   separate work item — the kernel + ethernet + storage + display path
   is the MVP.

### Plausible paths (pick one when this becomes work)

- **A. Forward-port the 5.4 vendor driver.** Hard but most fidelity.
  Track upstream `mt76` API changes and adapt the vendor code chunk by
  chunk. Best for confidence.
- **B. Wait for upstream mt76 to gain 7668 support.** Lowest effort but
  not under our control.
- **C. Use a USB WiFi dongle.** Lazy fallback; ignores onboard Baikal
  WiFi/BT entirely. Useful for early testing.

### How to confirm the gap

```sh
ls tmp/crashniels-6.15/drivers/net/wireless/mediatek/
# → Kconfig, Makefile, mt76, mt7601u    (no mt76x8)
ls tmp/feeRnt-5.4.247-baikal/drivers/net/wireless/mediatek/
# → Kconfig, Makefile, mt76, mt7601u, mt76x8   (the vendor tree we want)
```
