# v94: Minimal ethtool Ops for ps4_mts

**Date:** 2026-05-13
**Source:** `drivers/net/ethernet/cadence/macb_main.c` ethtool block

## Ops Table

| Op | Why | Implementation |
|---|---|---|
| `get_drvinfo` | `ethtool -i` — driver name/version/fw-version | `strlcpy(info->driver, "ps4_mts", ...)`; firmware = BAR+0x0ac value |
| `get_link_ksettings` | `ethtool mts0` — speed/duplex/autoneg | Read BAR+0x04, decode bits 0/2-3/4 into ethtool constants; also read PHY BMCR/reg4/9 via SMI for AN state |
| `set_link_ksettings` | `ethtool -s mts0 speed 1000 duplex full autoneg on` | Write BMCR via SMI (restart AN or force speed), then set BAR+0x008 MAC_CTRL1 speed bits |
| `nway_reset` | `ethtool -r mts0` — restart autoneg | `mts_smi_c22_write(mts, 0, BMCR_ANRESTART \| BMCR_ANENABLE)` |
| `get_ringparam` | `ethtool -g mts0` — ring sizes | Report tx_count=256, rx_count=256 (from MTS hardware) |
| `get_strings` + `get_sset_count` + `get_ethtool_stats` | `ethtool -S mts0` — per-queue counters | Read BAR+0x118 (TX frames), BAR+0x128 (RX frames), BAR+0x12c (RX errors) plus software mts_stats64 |
| `get_regs_len` + `get_regs` | `ethtool -d mts0` — register dump | Dump BAR0[0x000..0x200] as u32 array (256 bytes) |

## Code Snippets

### ethtool_ops struct

```c
static const struct ethtool_ops mts_ethtool_ops = {
    .get_drvinfo         = mts_get_drvinfo,
    .get_link            = ethtool_op_get_link,
    .get_link_ksettings  = mts_get_link_ksettings,
    .set_link_ksettings  = mts_set_link_ksettings,
    .nway_reset          = mts_nway_reset,
    .get_ringparam       = mts_get_ringparam,
    .get_strings         = mts_get_strings,
    .get_sset_count      = mts_get_sset_count,
    .get_ethtool_stats   = mts_get_ethtool_stats,
    .get_regs_len        = mts_get_regs_len,
    .get_regs            = mts_get_regs,
};
```

### get_link_ksettings (from BAR+0x04, no phylib)

```c
static int mts_get_link_ksettings(struct net_device *dev,
                                  struct ethtool_link_ksettings *kset)
{
    struct mts *mts = netdev_priv(dev);
    u32 ls = readl(mts->bar + MTS_LINK_STATUS);

    ethtool_link_ksettings_zero_link_mode(kset, supported);
    ethtool_link_ksettings_zero_link_mode(kset, advertising);
    /* PHY supports 10/100/1000 FD */
    __set_bit(ETHTOOL_LINK_MODE_10baseT_Half_BIT,  kset->link_modes.supported);
    __set_bit(ETHTOOL_LINK_MODE_10baseT_Full_BIT,  kset->link_modes.supported);
    __set_bit(ETHTOOL_LINK_MODE_100baseT_Half_BIT, kset->link_modes.supported);
    __set_bit(ETHTOOL_LINK_MODE_100baseT_Full_BIT, kset->link_modes.supported);
    __set_bit(ETHTOOL_LINK_MODE_1000baseT_Full_BIT, kset->link_modes.supported);
    __set_bit(ETHTOOL_LINK_MODE_Autoneg_BIT,       kset->link_modes.supported);
    __set_bit(ETHTOOL_LINK_MODE_TP_BIT,            kset->link_modes.supported);

    kset->base.autoneg = AUTONEG_ENABLE;
    kset->base.port = PORT_TP;

    if (ls & MTS_LINK_UP) {
        kset->base.duplex = (ls & MTS_LINK_FULL_DUPLEX) ? DUPLEX_FULL : DUPLEX_HALF;
        switch (ls & MTS_LINK_SPEED_MASK) {
        case MTS_LINK_SPEED_1000: kset->base.speed = SPEED_1000; break;
        case MTS_LINK_SPEED_100:  kset->base.speed = SPEED_100;  break;
        case MTS_LINK_SPEED_10:   kset->base.speed = SPEED_10;   break;
        default:                   kset->base.speed = SPEED_UNKNOWN;
        }
    } else {
        kset->base.speed = SPEED_UNKNOWN;
        kset->base.duplex = DUPLEX_UNKNOWN;
    }
    return 0;
}
```

### Stats strings + get

```c
#define MTS_STATS_LEN  6
static const char mts_stat_strings[][ETH_GSTRING_LEN] = {
    "rx_packets", "rx_bytes", "rx_errors", "rx_dropped",
    "tx_packets", "tx_bytes",
};

static int mts_get_sset_count(struct net_device *dev, int sset)
{
    return (sset == ETH_SS_STATS) ? MTS_STATS_LEN : -EOPNOTSUPP;
}

static void mts_get_strings(struct net_device *dev, u32 sset, u8 *p)
{
    if (sset == ETH_SS_STATS)
        memcpy(p, mts_stat_strings, sizeof(mts_stat_strings));
}

static void mts_get_ethtool_stats(struct net_device *dev,
                                   struct ethtool_stats *stats, u64 *data)
{
    struct mts *mts = netdev_priv(dev);
    data[0] = mts->stats.rx_packets;
    data[1] = mts->stats.rx_bytes;
    data[2] = mts->stats.rx_errors;
    data[3] = mts->stats.rx_dropped;
    data[4] = mts->stats.tx_packets;
    data[5] = mts->stats.tx_bytes;
}
```

### Wire into probe (one line)

```c
dev->ethtool_ops = &mts_ethtool_ops;
```

That's it — ~80 LOC total for ethtool. No phylib dependency; link state comes directly from BAR+0x04.