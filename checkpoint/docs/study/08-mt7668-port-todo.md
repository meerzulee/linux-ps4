# 08 — Porting MT7668 WiFi/BT to 6.x (TODO)

The MT7668 (mt76x8 vendor) WiFi+BT combo driver is in 5.4 but **not
in any 6.x reference tree**. Without it, 6.x boots without WiFi.
Ethernet is the alternative, but sky2 is currently broken on Baikal
(LAN comes up but doesn't pass useful traffic).

This is a long-running parallel task: spend host-side build time
between PS4 chains, no chains burned. Estimated ~1 day of compile-
error whack-a-mole, plus testing once the kernel boots.

## Source

```
tmp/feeRnt-5.4.247-baikal/drivers/net/wireless/mediatek/mt76x8/
```

~250 files, ~214k lines. Vendor MTK driver (not the in-tree `mt76`).
Includes firmware blobs.

## Step 1 — copy the tree

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
mkdir -p src/6.x-baikal/drivers/net/wireless/mediatek
cp -r tmp/feeRnt-5.4.247-baikal/drivers/net/wireless/mediatek/mt76x8 \
      src/6.x-baikal/drivers/net/wireless/mediatek/

# Wire it into Kconfig + Makefile
echo 'source "drivers/net/wireless/mediatek/mt76x8/Kconfig"' \
  >> src/6.x-baikal/drivers/net/wireless/mediatek/Kconfig
echo 'obj-$(CONFIG_MT76X8) += mt76x8/' \
  >> src/6.x-baikal/drivers/net/wireless/mediatek/Makefile
```

## Step 2 — Kconfig setup

Add to `config/6.x-baikal.config`:

```
CONFIG_MT76X8=y
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_MT76_CORE=y
```

(`=y` rather than `=m` matches what we did on 5.4 to bake the driver
into bzImage. Larger image but no module-load timing issues.)

## Step 3 — fix compile errors, expect ~10–30 of them

APIs likely to have changed between 5.4 and 6.x:

### NAPI

- 5.4: `napi->poll = my_poll(struct napi_struct *napi, int budget)` returning int.
- 6.x: same signature but `netif_napi_add()` no longer takes a weight arg
  (use `netif_napi_add_weight()` if you need a custom weight, otherwise
  use the default).
- Mass replace: `netif_napi_add(dev, napi, fn, weight)` →
  `netif_napi_add(dev, napi, fn)` if weight is NAPI_POLL_WEIGHT.

### cfg80211 / mac80211

- `cfg80211_*_register()` callback table changed names in places.
- `ieee80211_get_channel()` may have new parameter (cfg80211 wiphy
  ctx in 6.x).
- `ieee80211_register_hw()` deprecated some bits; check 6.x documentation.

### vmalloc / kvmalloc

- `vmalloc()` signatures unchanged.
- `kmalloc()` flags `__GFP_*` mostly stable.
- `pgprot_writecombine()` and friends — verify on 6.x.

### Network device ops

- `struct net_device_ops` gained new optional members; existing entries
  are stable.
- `ndo_change_mtu()` callback signature unchanged.

### Skbuff

- `skb_*` API mostly stable.
- `skb_set_queue_mapping()` unchanged.

### DMA

- This is the big one (also affects other drivers). 5.4 `dma_set_mask`
  → 6.x has `dma_set_mask_and_coherent` as a single call. Old patterns
  that called `pci_set_dma_mask()` need to switch to `dma_set_mask()`.
- DMA mask 31-bit usage — consistent with our other patches; check the
  exact API.

### Firmware loading

- `request_firmware_nowait()` callback signature stable.
- `release_firmware()` stable.
- Firmware blobs go in `firmware/`; CONFIG_EXTRA_FIRMWARE_DIR
  points at the project root (already set from 5.4 build infrastructure).

### Bluetooth

- The 5.4 patch SKIPPED the BT half because in-tree `btmtk` already
  exists in 5.4+. Same applies to 6.x — only port the WiFi (WLAN)
  side. Keep BT as a separate phase.

## Step 4 — generate a patch

Once compile-clean:

```sh
cd src/6.x-baikal
git add -A
git diff --cached drivers/net/wireless/mediatek/mt76x8/ \
  > ../../patches/6.x-baikal/0600-wifi-mt7668/0001-mediatek-mt7668-driver-merge-6.x.patch

# Add to series
mkdir -p patches/6.x-baikal/0600-wifi-mt7668
cat >> patches/6.x-baikal/series <<'EOF'

# === 0600: MediaTek MT7668 WiFi/BT vendor driver (forward-port from 5.4)
0600-wifi-mt7668/0001-mediatek-mt7668-driver-merge-6.x.patch
EOF
```

## Step 5 — test once 6.x boots

The boot test isn't separate from the main 6.x boot fix — once 6.x
boots at all, this driver either works or doesn't. If WiFi comes up,
done. If it crashes, debug the new driver in isolation.

## Time estimate

- Step 1 (copy + Kconfig wiring): 30 min.
- Step 2 (config): 5 min.
- Step 3 (compile fixes): 4–8 hours of API hunting. Most fixes will be
  small (1–3 line changes). The bulk of LOC won't need touching;
  it's the function-table glue and a handful of callbacks.
- Step 4 (patch generation): 10 min.
- Step 5 (test): 1 chain (when 6.x boot is fixed).

## Helpful references

- `tmp/feeRnt-5.4.247-baikal/drivers/net/wireless/mediatek/mt76x8/Kconfig`
  — original Kconfig, copy structure verbatim.
- `tmp/feeRnt-5.4.247-baikal/drivers/net/wireless/mediatek/mt76x8/Makefile`
  — same.
- `Documentation/networking/cfg80211-state-machine.txt` (in 6.15.4
  kernel tree) — refresher on cfg80211 lifecycle if confused.
- `git log --oneline drivers/net/wireless/ |
   sed -n '/v5.4/,/v6.15/p'` — see what changed in mainline wireless
  between the two kernel versions, hint to where APIs moved.

## Gotchas

- **Don't commit firmware blobs to git** if they're large. They live
  in `firmware/` and are gitignored. Check `firmware/.gitignore` and
  `EXTRA_FIRMWARE` config to make sure firmware paths are absolute.
- **MT7668 has multiple firmware variants** (E1 vs E2 silicon, USB
  vs SDIO). The PS4 uses the SDIO variant. Make sure the right
  firmware blob is loaded.
- **Built-in (`=y`) vs module (`=m`)**: `=y` works on 5.4 and bakes
  the driver into bzImage. We chose this on 5.4 for boot-time WiFi.
  Same approach for 6.x. Don't switch to `=m` unless you have a
  specific reason.

## Status tracker (update as you go)

- [ ] Step 1: tree copied, Kconfig wired
- [ ] Step 2: config flags set
- [ ] Step 3: compile-clean
- [ ] Step 4: patch generated, in series
- [ ] Step 5: tested on hardware
