// SPDX-License-Identifier: GPL-2.0
/*
 * eth_probe — out-of-tree kernel module to scan the Baikal Ethernet PHY
 * over all 32 MDIO addresses, printing which (if any) respond.
 *
 * sky2 is built-in on PS4 and binds at 0000:00:14.1 with phy_addr=1
 * (set by patch 0001), then immediately spams "phy I/O error" — meaning
 * the PHY isn't at address 1. To find where it actually is (or whether
 * the MDIO bus responds at any address), this module ioremaps the
 * GMAC SMI registers and walks the bus.
 *
 * Hotswap-friendly: insmod, read dmesg, rmmod. No reboot.
 *
 * Build (on host):
 *     make -C /home/meerzulee/Work/ps4/linux-ps4/src/6.x-baikal \
 *          M=$(pwd) modules
 * scp + insmod on PS4, then dmesg tail for results.
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/delay.h>

#define BAIKAL_VENDOR_SONY  0x104d
#define BAIKAL_GBE          0x90d8

/* From sky2.h */
#define BASE_GMAC_1         0x2800
#define GM_SMI_CTRL         0x0080
#define GM_SMI_DATA         0x0084
#define GM_SMI_CT_PHY_A_MSK 0xf800
#define GM_SMI_CT_REG_A_MSK 0x07c0
#define GM_SMI_CT_OP_RD     (1 << 5)
#define GM_SMI_CT_BUSY      (1 << 3)

#define PHY_ID0_REG         2
#define PHY_ID1_REG         3

static int eth_probe_read(void __iomem *bar, int phyad, int phyreg, u16 *out)
{
	u16 cmd, ctrl;
	int spins;

	cmd = ((phyad << 11) & GM_SMI_CT_PHY_A_MSK) |
	      ((phyreg << 6) & GM_SMI_CT_REG_A_MSK) |
	      GM_SMI_CT_OP_RD;

	writew(cmd, bar + BASE_GMAC_1 + GM_SMI_CTRL);

	for (spins = 0; spins < 1000; spins++) {
		ctrl = readw(bar + BASE_GMAC_1 + GM_SMI_CTRL);
		if (!(ctrl & GM_SMI_CT_BUSY)) {
			*out = readw(bar + BASE_GMAC_1 + GM_SMI_DATA);
			return 0;
		}
		udelay(10);
	}
	return -ETIMEDOUT;
}

static int __init eth_probe_init(void)
{
	struct pci_dev *pdev = NULL;
	void __iomem *bar;
	int phyad, r;
	u16 id0, id1;
	int hits = 0;

	pdev = pci_get_device(BAIKAL_VENDOR_SONY, BAIKAL_GBE, NULL);
	if (!pdev) {
		pr_err("eth_probe: PCI %04x:%04x not found\n",
		       BAIKAL_VENDOR_SONY, BAIKAL_GBE);
		return -ENODEV;
	}

	bar = pci_iomap(pdev, 0, 0);
	if (!bar) {
		pr_err("eth_probe: pci_iomap(BAR0) failed\n");
		pci_dev_put(pdev);
		return -EIO;
	}

	pr_info("eth_probe: found %04x:%04x, BAR0 ioremap=%p, scanning MDIO 0..31\n",
		BAIKAL_VENDOR_SONY, BAIKAL_GBE, bar);

	for (phyad = 0; phyad < 32; phyad++) {
		r = eth_probe_read(bar, phyad, PHY_ID0_REG, &id0);
		if (r) {
			pr_info("eth_probe: phyad %2d: TIMEOUT on ID0\n", phyad);
			continue;
		}
		r = eth_probe_read(bar, phyad, PHY_ID1_REG, &id1);
		if (r)
			id1 = 0xffff;

		if (id0 == 0xffff || id0 == 0) {
			/* "no PHY here" — quiet unless we want full verbosity */
			pr_info("eth_probe: phyad %2d: ID0=0x%04x ID1=0x%04x  (no PHY)\n",
				phyad, id0, id1);
		} else {
			pr_info("eth_probe: phyad %2d: ID0=0x%04x ID1=0x%04x  *** RESPONDS ***\n",
				phyad, id0, id1);
			hits++;
		}
	}

	pr_info("eth_probe: scan complete, %d address(es) responded\n", hits);

	pci_iounmap(pdev, bar);
	pci_dev_put(pdev);

	/* Refuse to fully load — we did our work in init. Returning negative
	 * causes the module to be unloaded immediately. */
	return -ECANCELED;
}

static void __exit eth_probe_exit(void)
{
	pr_info("eth_probe: exit\n");
}

module_init(eth_probe_init);
module_exit(eth_probe_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PS4 Linux Project");
MODULE_DESCRIPTION("Probe Baikal Ethernet PHY via MDIO scan");
