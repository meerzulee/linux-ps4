# deepseek-v106-ship-checklist-final-hail-mary.md — 2026-05-14

## Q1 — Minimum-viable diff to ship RX-only driver (~80 LOC)

The driver already has working netdev + NAPI RX + carrier tracking + MAC/PHY
init.  What's missing for a usable monitoring tool:

### Essential (30 LOC)

```c
/* ethtool ops — enables `ethtool enp0s20f1` and `ethtool -S` */
static void mts_ethtool_get_drvinfo(struct net_device *ndev,
                                     struct ethtool_drvinfo *info) {
    strscpy(info->driver, DRV_NAME, sizeof(info->driver));
    strscpy(info->bus_info, pci_name(((struct mts *)netdev_priv(ndev))->pdev),
            sizeof(info->bus_info));
}

static int mts_ethtool_get_link_ksettings(struct net_device *ndev,
                                           struct ethtool_link_ksettings *cmd) {
    struct mts *mts = netdev_priv(ndev);
    u32 linkreg = readl(mts->bar + MTS_LINK_STATUS);
    cmd->base.speed = (linkreg & MTS_LINK_SPEED_MASK) == MTS_LINK_SPEED_1000
                      ? SPEED_1000 : SPEED_10;
    cmd->base.duplex = (linkreg & MTS_LINK_FULL_DUPLEX) ? DUPLEX_FULL
                                                          : DUPLEX_HALF;
    cmd->base.port = PORT_MII;
    cmd->base.autoneg = AUTONEG_ENABLE;
    return 0;
}

static const struct ethtool_ops mts_ethtool_ops = {
    .get_drvinfo           = mts_ethtool_get_drvinfo,
    .get_link_ksettings    = mts_ethtool_get_link_ksettings,
    .get_link              = ethtool_op_get_link,
};
ndev->ethtool_ops = &mts_ethtool_ops;  /* in probe */
```

### Documentation (header comment block)

```
 * Known limitations (2026-05-14):
 *   - TX path is non-functional.  The Baikal MAC's TX descriptor engine
 *     requires the silicon-level link-up latch (BAR+0x04 bit 0) to
 *     transition before TX DMA fetches begin.  Our driver cannot satisfy
 *     this one-shot hardware requirement after kexec from Orbis.
 *   - Use case: passive monitor / packet capture (tcpdump -i enp0s20f1).
 *   - Link state tracked via PHY BMSR polling (v94 kthread).
 *   - For TX-capable Ethernet, see the sky2 shell approach in
 *     patches/6.x-baikal/0700-network-sky2/.
```

### Optional polish (50 LOC)
- ethtool `get_ringparam` (report 256 / 256)
- sysfs `stats/rx_packets` via ndo_get_stats64 (already wired in v93)
- `/proc/net/dev` counters already populated by netdev core

## Q2 — Hail Mary final audit: no missed register

Re-audited every BAR offset touched by ANY Orbis function:

- `mts_mac_init` (0x200,0x050,0x0ac,0x07c,0x078,0x014,0x018,0x140,0x144,
  0x00c,0x074,0x008,0x1d4,0x010,0x030,0x1bc-0x1d0) — all replicated
- `mts_init_rings_kick` (0x044,0x03c,0x048,0x040,0x034,0x038,0x054) — all
- Parent prelude (0xf10,0xf04,0x060,0x064,0x068,0x06c,0x120,0x11c,0x158)
- `msk_init_hw` adds (0x004,0x00c,0x014,0x138,0xe08,0xe18,0xe80-0xf80,
  0x1000-0x17fc) — 0x004/0x00c/0x014 destructive; 0xe80+ doesn't exist on
  Baikal; 0x138 tried and failed; multicast at 0x1000+ replicated
- `FUN_c85f1890`/`FUN_c85f1aa0` — TX submit, no new BAR registers
- `FUN_c85f2250` — switch management, uses FUN_c85f1890 for TX

BAR+0x002: not a valid 32-bit register.  BAR+0x100/0x300: never written by
any Orbis path.  BAR+0x208/0x210: hardware self-set status, no Orbis write.

NETIF_F_NO_CSUM: software flag, no hardware effect.

**Hail Mary verdict: genuinely exhausted.**  Commit RX-only, document the
limitation, move on.

--- deepseek-v41, 2026-05-14
