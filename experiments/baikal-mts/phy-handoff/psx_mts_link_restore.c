// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (C) 2026 Meerzulee and Linux psX contributors */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt
#include <linux/device.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/ioport.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/string.h>
#include <linux/utsname.h>

#define EXPECTED_RELEASE "6.18.44-ps4-baikal"
#define EXPECTED_OVERRIDE "psx_mts_packet_trace_retained"
#define MDIO_DONE BIT(15)
#define MDIO_READ BIT(14)
#define MDIO_WRITE BIT(13)
static const struct device_driver override_guard = {.name = EXPECTED_OVERRIDE};
static char cached_report[PAGE_SIZE];
static size_t report_bytes;

static int metadata(struct pci_dev *pdev, struct pci_dev *glue)
{
	u16 command, glue_command;
	if (pdev->vendor != 0x104d || pdev->device != 0x90d8 ||
	    glue->vendor != 0x104d || glue->device != 0x90db)
		return -ENODEV;
	if (pdev->driver || pdev->dev.driver || pdev->current_state != PCI_D0 ||
	    device_match_driver_override(&pdev->dev, &override_guard) != 1 ||
	    !glue->driver || !glue->dev.driver ||
	    strcmp(glue->dev.driver->name, "baikal_pcie") ||
	    glue->current_state != PCI_D0)
		return -EBUSY;
	if (pci_read_config_word(pdev, PCI_COMMAND, &command) != PCIBIOS_SUCCESSFUL ||
	    pci_read_config_word(glue, PCI_COMMAND, &glue_command) != PCIBIOS_SUCCESSFUL)
		return -EIO;
	if (command != 0x0546 || glue_command != 0x0546 ||
	    pci_resource_start(pdev, 0) != 0xc2000000ULL ||
	    pci_resource_len(pdev, 0) != 0x1000 ||
	    pci_resource_flags(pdev, 0) != 0x140204 ||
	    pci_resource_start(glue, 2) != 0xc8800000ULL ||
	    pci_resource_len(glue, 2) != 0x200000 ||
	    pci_resource_flags(glue, 2) != 0x140204)
		return -EINVAL;
	return 0;
}

struct mdio_sample {
	u32 reg, command, raw;
	bool final_read;
	u64 start_ns, end_ns;
	int error;
	bool attempted, command_issued, completed;
};

/* Native252800/252640/252490 MDIO transport, fixed PHY0 only.
 * One MMD30:0147 data write clears observed0010 to0000; never force-up0018.
 * No DMA publication, MAC mode, AN restart or other PHY setting change.
 */
static int mdio_command(void __iomem *mac, struct mdio_sample *sample, u32 *writes)
{
	u32 initial;
	int error;
	sample->start_ns = ktime_get_boottime_ns();
	initial = readl(mac);
	sample->raw = initial;
	if (initial == U32_MAX || (initial & (MDIO_READ | MDIO_WRITE))) {
		sample->error = initial == U32_MAX ? -EIO : -EBUSY;
		goto out;
	}
	sample->attempted = true;
	writel(MDIO_DONE, mac);
	++*writes;
	/* Flush the W1C write and refuse a completion bit that did not clear. */
	initial = readl(mac);
	sample->raw = initial;
	if (initial == U32_MAX || (initial & (MDIO_DONE | MDIO_READ | MDIO_WRITE))) {
		sample->error = -EIO;
		goto out;
	}
	writel(sample->command, mac);
	++*writes;
	sample->command_issued = true;
	error = readl_poll_timeout(mac, sample->raw,
		(sample->raw & MDIO_DONE) || sample->raw == U32_MAX, 10, 10000);
	if (error || sample->raw == U32_MAX ||
	    (sample->raw & (MDIO_READ | MDIO_WRITE))) {
		sample->error = error ? error : -EIO;
		goto out;
	}
	if (sample->final_read) {
		/* Native2527bb rereads +00 after successful extended data phase. */
		sample->raw = readl(mac);
		if (sample->raw == U32_MAX || !(sample->raw & MDIO_DONE)) {
			sample->error = -EIO;
			goto out;
		}
	}
	sample->completed = true;
out:
	sample->end_ns = ktime_get_boottime_ns();
	return sample->error;
}

static int report_get(char *buffer, const struct kernel_param *parameter)
{
	(void)parameter;
	memcpy(buffer, cached_report, report_bytes);
	return (int)report_bytes;
}
static const struct kernel_param_ops report_ops = {.get = report_get};
module_param_cb(report, &report_ops, NULL, 0400);
MODULE_PARM_DESC(report, "Cached one MMD30:0147 clear and status observations; no live accesses");

static int __init observer_init(void)
{
	struct pci_dev *pdev = NULL, *glue = NULL;
	struct module *glue_owner = NULL;
	void __iomem *mac = NULL, *gate = NULL;
	bool pdev_locked = false, glue_locked = false, owner_pinned = false;
	bool unchanged = false, valid = false, phy_write_attempted = false;
	u64 first_mac_link_ns = 0;
	u32 mac_link_sample = 0, poll;
	struct mdio_sample samples[] = {
		{.reg = 2, .command = 0x4200},
		{.reg = 3, .command = 0x4300},
		{.reg = 31, .command = 0x5f00},
		{.reg = 0, .command = 0x4000},
		{.reg = 1, .command = 0x4100},
		{.reg = 1, .command = 0x4100},
		{.reg = 0x147, .command = 0x01471e20},
		{.reg = 0x147, .command = 0x00001ee0, .final_read = true},
		{.reg = 0x147, .command = 0x01471e20},
		{.reg = 0x147, .command = 0x00001e60},
		{.reg = 0x147, .command = 0x01471e20},
		{.reg = 0x147, .command = 0x00001ee0, .final_read = true},
		{.reg = 1, .command = 0x4100},
		{.reg = 1, .command = 0x4100}};
	u32 before = 0, after = 0, mac08 = 0, writes = 0, i;
	int error = -EINVAL;

	if (strcmp(init_utsname()->release, EXPECTED_RELEASE))
		goto out;
	pdev = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(0x14, 1));
	glue = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(0x14, 4));
	if (!pdev || !glue) {
		error = -ENODEV;
		goto out;
	}
	if (!device_trylock(&pdev->dev)) {
		error = -EBUSY;
		goto out;
	}
	pdev_locked = true;
	if (!device_trylock(&glue->dev)) {
		error = -EBUSY;
		goto out;
	}
	glue_locked = true;
	error = metadata(pdev, glue);
	if (error)
		goto out;
	glue_owner = glue->dev.driver->owner;
	if (!try_module_get(glue_owner)) {
		error = -EBUSY;
		goto out;
	}
	owner_pinned = true;
	/* The original trace retains BAR0; take and release no BAR reservation. */
	mac = pci_iomap_range(pdev, 0, 0, 0x58);
	gate = pci_iomap_range(glue, 2, 0x110450, 4);
	if (!mac || !gate) {
		error = -ENOMEM;
		goto out;
	}
	before = readl(mac + 4);
	mac08 = readl(mac + 8);
	if (before != 0x00000b18 || mac08 != 0x0f597c00 ||
	    readl(mac + 0x34) != 0 || readl(mac + 0x38) != 0 ||
	    readl(mac + 0x54) != 0x007ffffa || readl(gate) != 0) {
		error = -EBUSY;
		goto out;
	}
	for (i = 0; i < ARRAY_SIZE(samples); ++i) {
		/* Recheck the stopped baseline immediately before address/data write. */
		if ((i == 8 || i == 9) &&
		    (readl(mac + 4) != 0x00000b18 || readl(mac + 8) != mac08 ||
		     readl(mac + 0x34) != 0 || readl(mac + 0x38) != 0 ||
		     readl(mac + 0x54) != 0x007ffffa || readl(gate) != 0)) {
			error = -EBUSY;
			break;
		}
		/* Latch attempted before any command that could change the PHY setting. */
		if (i == 9)
			phy_write_attempted = true;
		if (i == 12) {
			/* Up to5seconds of MAC link polling; no further configuration write. */
			for (poll = 0; poll < 50; ++poll) {
				mac_link_sample = readl(mac + 4);
				if (mac_link_sample == U32_MAX) {
					error = -EIO;
					break;
				}
				if (mac_link_sample & 1) {
					first_mac_link_ns = ktime_get_boottime_ns();
					break;
				}
				msleep(100);
			}
			if (error)
				break;
		}
		error = mdio_command(mac, &samples[i], &writes);
		if (error)
			break;
		/* Require the positively identified PHY before extended commands. */
		if (i == 1 && ((samples[0].raw >> 16) != 0x03a2 ||
			(samples[1].raw >> 16) != 0x9441)) {
			error = -ENODEV;
			break;
		}
		/* Preserve page selection; refuse rather than selecting page0. */
		if (i == 2 && (samples[i].raw >> 16) != 0) {
			error = -EINVAL;
			break;
		}
		if ((i == 3 && (samples[i].raw >> 16) != 0x1040) ||
		    ((i == 4 || i == 5) && (samples[i].raw >> 16) != 0x7969) ||
		    (i == 7 && (samples[i].raw >> 16) != 0x0010)) {
			error = -ESTALE;
			break;
		}
		if (i == 11 && (samples[i].raw >> 16) != 0) {
			error = -EIO;
			break;
		}
	}
	after = readl(mac + 4);
	unchanged = metadata(pdev, glue) == 0 &&
		readl(mac + 8) == mac08 && readl(mac + 0x34) == 0 &&
		readl(mac + 0x38) == 0 &&
		readl(mac + 0x54) == 0x007ffffa && readl(gate) == 0;
	valid = !error && unchanged && after != U32_MAX;
out:
	/* No memory or code address has been published; MDIO uses only +00. */
	if (gate)
		pci_iounmap(glue, gate);
	if (mac)
		pci_iounmap(pdev, mac);
	if (owner_pinned)
		module_put(glue_owner);
	if (glue_locked)
		device_unlock(&glue->dev);
	if (pdev_locked)
		device_unlock(&pdev->dev);
	pci_dev_put(glue);
	pci_dev_put(pdev);
	report_bytes = scnprintf(cached_report, sizeof(cached_report),
		"{\"valid\":%s,\"error\":%d,\"metadata_unchanged\":%s,\"phy_address\":0,\"controller_writes\":%u,\"phy_write_attempted\":%s,\"phy_setting_write_commands\":%u,\"phy_address_phases\":%u,\"mac_link_sample\":\"%08x\",\"first_mac_link_ns\":%llu,\"dma_publications\":0,\"mac04_before\":\"%08x\",\"mac04_after\":\"%08x\",\"mac08\":\"%08x\",\"samples\":[",
		valid ? "true" : "false", error, unchanged ? "true" : "false",
		writes, phy_write_attempted ? "true" : "false",
		samples[9].command_issued ? 1 : 0,
		(unsigned int)samples[6].command_issued + samples[8].command_issued +
			samples[10].command_issued,
		mac_link_sample, (unsigned long long)first_mac_link_ns,
		before, after, mac08);
	for (i = 0; i < ARRAY_SIZE(samples); ++i)
		report_bytes += scnprintf(cached_report + report_bytes,
			sizeof(cached_report) - report_bytes,
			"%s{\"reg\":%u,\"command\":\"%08x\",\"attempted\":%s,\"command_issued\":%s,\"completed\":%s,\"error\":%d,\"raw\":\"%08x\",\"value\":\"%04x\",\"start_ns\":%llu,\"end_ns\":%llu}",
			i ? "," : "", samples[i].reg, samples[i].command,
			samples[i].attempted ? "true" : "false",
			samples[i].command_issued ? "true" : "false",
			samples[i].completed ? "true" : "false", samples[i].error,
			samples[i].raw, samples[i].raw >> 16,
			(unsigned long long)samples[i].start_ns,
			(unsigned long long)samples[i].end_ns);
	report_bytes += scnprintf(cached_report + report_bytes,
		sizeof(cached_report) - report_bytes, "]}\n");
	pr_info("MMD30:0147 one-clear finished: valid=%d error=%d attempted=%d write_completed=%d readback=%04x MAC04=%08x->%08x BMSR=%04x/%04x; cached report only; no retry/restore/DMA\n",
		valid, error, phy_write_attempted, samples[9].completed,
		samples[11].raw >> 16, before, after,
		samples[12].raw >> 16, samples[13].raw >> 16);
	/* Return the cached failure as evidence rather than losing it at init. */
	return 0;
}

static void __exit observer_exit(void)
{
	pr_info("Link control helper unloaded; PHY setting left as observed; original retained trace untouched\n");
}
module_init(observer_init);
module_exit(observer_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Meerzulee and Linux psX contributors");
MODULE_DESCRIPTION("One observed MMD30:0147 bit4 clear; no DMA publication or automatic restore");
