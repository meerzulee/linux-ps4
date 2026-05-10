# sky2 dead-end on Baikal — proven via MDIO scan (2026-05-11)

**Verdict:** Sky2 driver is the wrong driver for Baikal's ethernet.
Closing the sky2 path permanently. Ethernet on Baikal 6.x requires a
different driver (almost certainly `stmmac` for Synopsys DWMAC1000) or
ground-up RE of the chip's PHY register layout.

## Summary

Across v67–v69 we made sky2 progress further than anyone has on Baikal:

| Stage | What we got past | How |
|---|---|---|
| **Detect PCI ID** | `0x90d8 = SONY_BAIKAL_GBE` | Existing 0001 patch (PCI ID table) |
| **Chip type read** | `B2_CHIP_ID` reads as 0x00 (unsupported) | v67 patch 0004: force `CHIP_ID_YUKON_PRM = 0xbd` |
| **PHY reset/init** | Aeolia-only IF blocks now match Baikal | v67 patch 0003: extend conditions |
| **MSI plumbing** | `sky2_test_msi` self-test fails (SW_IRQ trigger silent) | v67 patch 0005 + v68 patch 0006: skip the test |
| **Driver bind** | `eth0` registered as `enp0s20f1` | All above stacked |
| **PHY MDIO read** | **❌ No PHY at any of 32 MDIO addresses** | v69 patch 0007 scan — proved silicon |

## v69 diagnostic patch — what it does

`patches/6.x-baikal/0700-network-sky2/0007-sky2-baikal-mdio-scan-diagnostic.patch`

After `sky2_init` succeeds, sweep `hw->phy_addr` from 0..31, call
`__gm_phy_read(hw, 0, PHY_MARV_ID0, ...)` at each address, log every
response. Restores `hw->phy_addr` afterward — purely diagnostic.

## v69 boot result

UART excerpt from `checkpoint/uart-logs/2026-05-11_0255-v69-mdio-fresh.log`:

```
[ 4.367] sky2: driver version 1.30
[ 4.392] sky2 0000:00:14.1: PS4 Baikal: B2_CHIP_ID=0x0, forcing YUKON_PRM
[ 4.399] sky2 0000:00:14.1: chip type 0xbd
[ 4.404] sky2 0000:00:14.1: PS4 Baikal: MDIO scan starting (addrs 0..31)
[ 4.411] sky2 0000:00:14.1: (efault): phy I/O error    ← addr 0
[ 4.416] sky2 0000:00:14.1: (efault): phy I/O error    ← addr 1
[ 4.421] sky2 0000:00:14.1: (efault): phy I/O error    ← addr 2
... (28 more) ...
[ 4.589] sky2 0000:00:14.1: (efault): phy I/O error    ← addr 31
[ 4.594] sky2 0000:00:14.1: PS4 Baikal: MDIO scan complete, phy_addr restored to 1
```

**Zero of 32 addresses return non-error PHY ID registers.** The MDIO
bus is silent — no PHY chip on this bus at all.

Cable insertion changes nothing in dmesg post-boot. The interface
admin-state can be brought up but stays `NO-CARRIER` forever.

## Why sky2 reports a Yukon family chip ID

`B2_CHIP_ID` register reads 0x00 (not a real chip ID). Our v67 patch
0004 forces it to `CHIP_ID_YUKON_PRM = 0xbd`. Sky2's chip-table-driven
init then runs the Yukon-PRM init sequence — which happens to not
fail because it writes to register addresses that exist on Baikal but
have completely different semantics.

In other words: **we got the driver to BIND, but the silicon underneath
isn't actually Yukon-2.** The B2_CHIP_ID register, the MDIO bus, the
PHY block — these are all in different places (or absent) on Baikal.

## What Baikal's ethernet actually is (per rmuxnet's RE)

rmuxnet's `BAIKAL_DEVLOG.md`:

> Ethernet (GBE) | Baikal uses Synopsys DWMAC1000 (not Marvell Yukon
> like Aeolia). BAR0 is 4KB but DWMAC needs 8KB+. Needs glue BAR
> remapping — RE work in progress.

His independent RE matches what we observe:
- Sony's PCI ID is the same shape as Aeolia/Belize (`0x9?d8` slot 1),
  encouraging the assumption it's the same family
- Actual silicon is a different IP block (Synopsys DWMAC1000)
- Standard Yukon driver (sky2) cannot drive it — no PHY on the
  expected MDIO bus, no link possible

## Closing the sky2 track

**Patches kept** (sky2-Baikal patches remain in series for diagnostic
value and as a fallback if anyone reproduces with a different Baikal
revision):

- `0001-sky2-ps4-quirks.patch` — Baikal in PCI ID table
- `0003-sky2-baikal-belize-extend-aeolia-quirks.patch` — IF block extension
- `0004-sky2-baikal-override-chip-id-zero.patch` — chip_id force
- `0005-sky2-baikal-skip-msi-self-test.patch` — pci_enable_msi branch
- `0006-sky2-baikal-skip-msi-test-in-apcie-branch.patch` — APCIE branch
- `0007-sky2-baikal-mdio-scan-diagnostic.patch` — diagnostic

If you want to disable them: comment out lines 0003–0007 in
`patches/6.x-baikal/series`. They produce a registered-but-DOWN `enp0s20f1`
interface and ~8 `phy I/O error` messages per boot. Harmless but noisy.

**Patches added for ethernet from this point** would go in a new
subsystem directory: `0750-network-stmmac/` for the DWMAC1000 attempt.

## Next steps (separate effort)

Two paths to investigate, in order:

1. **Try mainline `stmmac` driver** — Linux has the DWMAC1000 driver
   already (`drivers/net/ethernet/stmicro/stmmac/`). It binds via
   `stmmac_pci` for PCI-attached DWMAC. Need to:
   - Add Baikal `0x90d8` to `stmmac_pci_id_table`
   - Handle Baikal's BAR0=4KB constraint (DWMAC normally wants 8KB+)
   - Provide PHY description (likely an integrated 88E1011 or similar
     Marvell PHY, but on a different bus than MDIO)
   - PS4-specific MSI plumbing through bpcie

2. **Reverse-engineer Baikal's PHY block location** — if stmmac doesn't
   bind, RE work is needed. mmap BAR0 from userspace via
   `/sys/bus/pci/devices/0000:00:14.1/resource0`, probe register
   offsets for what looks like PHY ID registers (Marvell OUI 0x141 or
   Realtek 0x732 etc.). Use that as a base for a from-scratch driver.

Both efforts are days-to-weeks; sky2 is closed. Internal MT7668 WiFi +
USB rtw88 adapter cover network connectivity in the meantime.
