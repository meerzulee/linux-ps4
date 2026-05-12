# eth_probe — hotswap MDIO scanner for Baikal GbE PHY

Standalone out-of-tree kernel module that scans all 32 MDIO addresses on
the PS4 Baikal Ethernet controller (`104d:90d8`) and prints which (if any)
PHY ID register responds with non-trivial values. Useful for finding the
PHY that mainline `sky2` can't locate — we observe 8x `phy I/O error` at
boot meaning sky2's hardcoded address is wrong.

**Hotswap**: insmod, read dmesg, rmmod. No kernel reboot.

## Build

```bash
make            # builds eth_probe.ko against project's 6.x-baikal tree
```

The Makefile points at `../../../src/6.x-baikal` by default. Override
with `KERNEL_DIR=/path/to/other/kernel make`.

## Deploy + run

```bash
scp eth_probe.ko ps4:/tmp/
ssh ps4 'sudo insmod /tmp/eth_probe.ko'   # returns ECANCELED (251) — expected,
                                          # module unloads itself after the scan
ssh ps4 'sudo dmesg | grep eth_probe'
```

The module returns `-ECANCELED` from its `init` so the kernel unloads it
right after the scan — no leftover state. Re-insmod to re-scan.

## Output

```
eth_probe: found 104d:90d8, BAR0 ioremap=0xffffXXXX, scanning MDIO 0..31
eth_probe: phyad  0: ID0=0xffff ID1=0xffff  (no PHY)
eth_probe: phyad  1: ID0=0xffff ID1=0xffff  (no PHY)
...
eth_probe: phyad  N: ID0=0x0141 ID1=0x0CC2  *** RESPONDS ***
eth_probe: scan complete, 1 address(es) responded
```

`0x0141` is Marvell's OUI prefix in PHY ID0. If we see that, the PHY is
just at the wrong address (sky2 patch 0001 hardcodes `phy_addr=1`); the
fix is to change that to the responding address.

If the scan shows **0 responses across all 32 addresses**, the MDIO bus
itself isn't working — the PHY may need explicit power-on or reset via
a side-channel (likely ICC).

## What this teaches us about hotswap workflow

sky2 itself is built-in (`CONFIG_SKY2=y`), so it can't be rmmod-ed.
But the GMAC's SMI registers (used for MDIO transactions) are plain
PCI BAR memory — any kernel module can map them and issue MDIO reads
in parallel with sky2. This lets us experiment with PHY behaviour
without rebuilding the base kernel.

The same pattern works for any "I want to poke hardware registers from
outside the in-tree driver" need: write a small out-of-tree module,
`pci_iomap()` the BAR, do the experiment, return `-ECANCELED` to
auto-unload.
