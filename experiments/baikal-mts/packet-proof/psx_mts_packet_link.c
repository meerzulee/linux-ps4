// SPDX-License-Identifier: GPL-2.0-only
/* Publication derivative: peer MAC replaced by a locally administered example.
 * This is not byte-identical to the source used for EXP-20261017-013.
 * See ../README.md; the integrated kernel driver is unaffected.
 */
/* Copyright (C) 2026 Meerzulee and Linux psX contributors */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-mapping.h>
#include <linux/errno.h>
#include <linux/gfp.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/ioport.h>
#include <linux/iommu-dma.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/string.h>
#include <linux/utsname.h>

#include "mts_prepare.h"

#define MTS_RELEASE "6.18.44-ps4-baikal"
#define MTS_OVERRIDE "psx_mts_packet_trace_retained"
#define MTS_VENDOR 0x104d
#define MTS_GBE_ID 0x90d8
#define MTS_GLUE_ID 0x90db
#define MTS_SLOT 0x14
#define MTS_GBE_COMMAND 0x0546
#define MTS_MAC_MAP_BYTES 0x58
#define MTS_PHY_CONTROL1 0x04
#define MTS_EXPECTED_PHY_CONTROL1 0x00000b19
#define MTS_TX_CONTROL 0x34
#define MTS_RX_CONTROL 0x38
#define MTS_TX_RING_BASE 0x3c
#define MTS_RX_RING_BASE 0x40
#define MTS_TX_RING_CURSOR 0x44
#define MTS_RX_RING_CURSOR 0x48
#define MTS_MAC_STATUS 0x50
#define MTS_MAC_MASK 0x54
#define MTS_STOP_MASK 0x007ffffa
#define MTS_FUNC1_MASK_OFFSET 0x110450
#define MTS_POLL_SLEEP_US 10
#define MTS_STOP_DEADLINE_US 2000000
#define MTS_PACKET_DEADLINE_MS 5000
#define MTS_FRAME_BYTES 60u
#define MTS_TX_PACKET_BYTES 0x600u
#define MTS_TX_FRAME_WORD0 ((u32)(BIT(31) | BIT(29) | BIT(28) | MTS_FRAME_BYTES))

struct mts_bar {
	resource_size_t start;
	resource_size_t length;
	unsigned long flags;
};

struct mts_caps {
	int msi_pos;
	int msix_pos;
	u16 msi_flags;
	u16 msix_flags;
};

struct mts_descriptor {
	__le32 word[4];
};

struct mts_dma_extent {
	mts_u64 dma;
	size_t size;
};

/* Fixed EXP007 extents: never dereference, modify or free original state. */
static const struct mts_dma_extent old_dma[] = {
	{0x0111c000, 0x4000},
	{0x01140000, 0x4000},
	{0x01180000, 0x60000},
	{0x0111b000, 0x600},
};

struct mts_packet_state {
	struct pci_dev *gbe;
	struct pci_dev *glue;
	struct device_driver *glue_driver;
	struct module *glue_owner;
	bool gbe_locked;
	bool glue_locked;
	bool owner_held;
	void __iomem *mac;
	void __iomem *function_mask;
	struct mts_bar gbe_bar;
	struct mts_bar glue_bar;
	struct mts_caps caps;
	u16 glue_command;
	struct mts_prepared memory;
	void *tx_packet;
	dma_addr_t tx_packet_dma;
	u8 nonce_bytes[16];
	u8 tx_frame[MTS_FRAME_BYTES];
	u8 rx_frame[MTS_FRAME_BYTES];
	bool prepared;
	bool attempted;
	bool retained;
	bool published;
	bool submitted;
	bool tx_completed;
	bool rx_matched;
	bool stopack;
	u32 txd0;
	u32 txd2;
	u32 rxd0;
	u32 tx_control;
	u32 rx_control;
	u32 mac_mask;
	u32 routing_gate;
	u32 phy_ctrl1_baseline;
	bool dma_nonoverlap_checked;
	u32 tx_before_enable;
	u32 rx_before_enable;
	u32 tx_before_kick;
	u32 tx_after_kick;
	u32 tx_before_stop;
	u32 rx_before_stop_after_tx_stop;
	u32 tx_reg3c_stop_entry;
	u32 rx_reg40_stop_entry;
	u32 status50_stop_entry;
	bool tx_before_enable_sampled;
	bool rx_before_enable_sampled;
	bool tx_before_kick_sampled;
	bool tx_after_kick_sampled;
	bool tx_before_stop_sampled;
	bool rx_before_stop_after_tx_stop_sampled;
	bool stop_entry_sampled;
	size_t rx_length;
	unsigned int rx_slot;
	int error;
	int stop_error;
	const char *stage;
};

/* Name token only: never registered or bound as a driver. */
static const struct device_driver override_guard = {.name = MTS_OVERRIDE};

static struct mts_packet_state packet;
static DEFINE_MUTEX(action_mutex);
static char *nonce;
module_param(nonce, charp, 0444);
MODULE_PARM_DESC(nonce, "Required 32 hexadecimal characters; 16-byte one-shot nonce");

static void mts_snapshot_bar(struct pci_dev *pdev, int bar, struct mts_bar *out)
{
	out->start = pci_resource_start(pdev, bar);
	out->length = pci_resource_len(pdev, bar);
	out->flags = pci_resource_flags(pdev, bar);
}

static bool mts_same_bar(struct pci_dev *pdev, int bar,
			 const struct mts_bar *before)
{
	return pci_resource_start(pdev, bar) == before->start &&
		pci_resource_len(pdev, bar) == before->length &&
		pci_resource_flags(pdev, bar) == before->flags;
}

static bool mts_identity(struct pci_dev *pdev, u16 device, unsigned int function)
{
	return pdev->vendor == MTS_VENDOR && pdev->device == device &&
		pci_domain_nr(pdev->bus) == 0 && pdev->bus->number == 0 &&
		PCI_SLOT(pdev->devfn) == MTS_SLOT &&
		PCI_FUNC(pdev->devfn) == function;
}

static int mts_metadata(struct mts_packet_state *state)
{
	struct device *dev = &state->gbe->dev;

	if (!mts_identity(state->gbe, MTS_GBE_ID, 1) ||
	    !mts_identity(state->glue, MTS_GLUE_ID, 4))
		return -ENODEV;
	if (state->gbe->driver || dev->driver || state->gbe->msi_enabled ||
	    state->gbe->msix_enabled || state->gbe->current_state != PCI_D0 ||
	    device_match_driver_override(dev, &override_guard) != 1)
		return -EBUSY;
	if (!state->glue->dev.driver ||
	    strcmp(state->glue->dev.driver->name, "baikal_pcie") ||
	    state->glue->current_state != PCI_D0)
		return -EBUSY;
	if (state->glue_driver &&
	    (state->glue->dev.driver != state->glue_driver ||
	     state->glue_driver->owner != state->glue_owner))
		return -EBUSY;
	if (!dev->dma_mask || *dev->dma_mask != DMA_BIT_MASK(32) ||
	    dev->coherent_dma_mask != DMA_BIT_MASK(32) || get_dma_ops(dev) ||
	    use_dma_iommu(dev) || !dev_is_dma_coherent(dev))
		return -EOPNOTSUPP;
#ifdef CONFIG_DMA_DECLARE_COHERENT
	if (dev->dma_mem)
		return -EOPNOTSUPP;
#endif
	return 0;
}

static int mts_read_commands(struct mts_packet_state *state, u16 *gbe, u16 *glue)
{
	if (pci_read_config_word(state->gbe, PCI_COMMAND, gbe) != PCIBIOS_SUCCESSFUL ||
	    pci_read_config_word(state->glue, PCI_COMMAND, glue) != PCIBIOS_SUCCESSFUL)
		return -EIO;
	if (*gbe != MTS_GBE_COMMAND || *glue == 0xffff ||
	    !(*glue & PCI_COMMAND_MEMORY))
		return -EINVAL;
	return 0;
}

static int mts_read_disabled_caps(struct pci_dev *pdev, struct mts_caps *caps)
{
	caps->msi_pos = pci_find_capability(pdev, PCI_CAP_ID_MSI);
	caps->msix_pos = pci_find_capability(pdev, PCI_CAP_ID_MSIX);
	caps->msi_flags = 0;
	caps->msix_flags = 0;
	if (caps->msi_pos) {
		if (pci_read_config_word(pdev, caps->msi_pos + PCI_MSI_FLAGS,
					 &caps->msi_flags) != PCIBIOS_SUCCESSFUL)
			return -EIO;
		if (caps->msi_flags & PCI_MSI_FLAGS_ENABLE)
			return -EBUSY;
	}
	if (caps->msix_pos) {
		if (pci_read_config_word(pdev, caps->msix_pos + PCI_MSIX_FLAGS,
					 &caps->msix_flags) != PCIBIOS_SUCCESSFUL)
			return -EIO;
		if (caps->msix_flags & PCI_MSIX_FLAGS_ENABLE)
			return -EBUSY;
	}
	return 0;
}

static bool mts_same_caps(const struct mts_caps *a, const struct mts_caps *b)
{
	return a->msi_pos == b->msi_pos && a->msix_pos == b->msix_pos &&
		a->msi_flags == b->msi_flags && a->msix_flags == b->msix_flags;
}

static void mts_unlock_devices(struct mts_packet_state *state)
{
	if (state->glue_locked) {
		device_unlock(&state->glue->dev);
		state->glue_locked = false;
	}
	if (state->gbe_locked) {
		device_unlock(&state->gbe->dev);
		state->gbe_locked = false;
	}
}

static int mts_trylock_devices(struct mts_packet_state *state)
{
	if (!device_trylock(&state->gbe->dev))
		return -EBUSY;
	state->gbe_locked = true;
	if (!device_trylock(&state->glue->dev)) {
		mts_unlock_devices(state);
		return -EBUSY;
	}
	state->glue_locked = true;
	return 0;
}

static int mts_read_stopped(struct mts_packet_state *state)
{
	state->tx_control = readl(state->mac + MTS_TX_CONTROL);
	state->rx_control = readl(state->mac + MTS_RX_CONTROL);
	state->mac_mask = readl(state->mac + MTS_MAC_MASK);
	state->routing_gate = readl(state->function_mask);
	if (state->tx_control == 0xffffffff || state->rx_control == 0xffffffff ||
	    state->mac_mask == 0xffffffff || state->routing_gate == 0xffffffff)
		return -EIO;
	if (((state->tx_control | state->rx_control) & 3u) ||
	    state->mac_mask != MTS_STOP_MASK || state->routing_gate != 0)
		return -EBUSY;
	return 0;
}

static int mts_revalidate(struct mts_packet_state *state, bool stopped)
{
	struct mts_caps caps = {0};
	u16 gbe = 0, glue = 0;
	int error;

	error = mts_metadata(state);
	if (error)
		return error;
	if (!mts_same_bar(state->gbe, 0, &state->gbe_bar) ||
	    !mts_same_bar(state->glue, 2, &state->glue_bar))
		return -EIO;
	error = mts_read_commands(state, &gbe, &glue);
	if (error)
		return error;
	if (glue != state->glue_command)
		return -EIO;
	error = mts_read_disabled_caps(state->gbe, &caps);
	if (error)
		return error;
	if (!mts_same_caps(&state->caps, &caps))
		return -EIO;
	return stopped ? mts_read_stopped(state) : 0;
}

/* Init/arm only: stop acknowledgements retain the original trace semantics. */
static int mts_read_link_baseline(struct mts_packet_state *state)
{
	int error = mts_read_stopped(state);

	if (error)
		return error;
	state->phy_ctrl1_baseline = readl(state->mac + MTS_PHY_CONTROL1);
	if (state->phy_ctrl1_baseline == 0xffffffff)
		return -EIO;
	if (state->tx_control != 0 || state->rx_control != 0 ||
	    state->phy_ctrl1_baseline != MTS_EXPECTED_PHY_CONTROL1)
		return -EBUSY;
	return 0;
}

static int mts_revalidate_link_baseline(struct mts_packet_state *state)
{
	int error = mts_revalidate(state, false);

	return error ? error : mts_read_link_baseline(state);
}

/* Call only after full 32-bit extent validation; inclusive ends cannot overflow. */
static bool mts_extents_overlap(const struct mts_dma_extent *a,
				const struct mts_dma_extent *b)
{
	return a->dma <= b->dma + b->size - 1 &&
		b->dma <= a->dma + a->size - 1;
}

static int mts_validate_dma_nonoverlap(struct mts_packet_state *state)
{
	struct mts_dma_extent fresh[MTS_PREPARE_SLOT_COUNT + 1];
	unsigned int i, j;

	state->dma_nonoverlap_checked = false;
	for (i = 0; i < MTS_PREPARE_SLOT_COUNT; ++i) {
		const struct mts_prepare_resource *resource = &state->memory.resource[i];

		if (!resource->cpu || resource->size != mts_prepare_slot_size(i))
			return -EINVAL;
		fresh[i].dma = resource->dma;
		fresh[i].size = resource->size;
	}
	if (!state->tx_packet)
		return -EINVAL;
	fresh[MTS_PREPARE_SLOT_COUNT].dma = (mts_u64)state->tx_packet_dma;
	fresh[MTS_PREPARE_SLOT_COUNT].size = MTS_TX_PACKET_BYTES;
	for (i = 0; i < ARRAY_SIZE(old_dma); ++i)
		if (!mts_dma_extent_valid(old_dma[i].dma, old_dma[i].size))
			return -ERANGE;
	for (i = 0; i < ARRAY_SIZE(fresh); ++i) {
		if (!mts_dma_extent_valid(fresh[i].dma, fresh[i].size))
			return -ERANGE;
		if (i < MTS_PREPARE_RX_POOL && fresh[i].dma % MTS_RING_DMA_ALIGNMENT)
			return -EINVAL;
		for (j = 0; j < ARRAY_SIZE(old_dma); ++j)
			if (mts_extents_overlap(&fresh[i], &old_dma[j]))
				return -EADDRINUSE;
		for (j = 0; j < i; ++j)
			if (mts_extents_overlap(&fresh[i], &fresh[j]))
				return -EADDRINUSE;
	}
	state->dma_nonoverlap_checked = true;
	return 0;
}

static void *mts_allocate(void *ctx, enum mts_prepare_slot slot, size_t size,
			  mts_u64 *dma)
{
	struct mts_packet_state *state = ctx;
	dma_addr_t handle = 0;
	void *cpu;

	cpu = dma_alloc_coherent(&state->gbe->dev, size, &handle,
				 GFP_KERNEL | __GFP_NOWARN | __GFP_NORETRY);
	*dma = (mts_u64)handle;
	pr_info("allocate slot=%u size=%zu dma=%016llx cpu-present=%u\n",
		slot, size, (unsigned long long)*dma, !!cpu);
	return cpu;
}

static void mts_free(void *ctx, enum mts_prepare_slot slot, size_t size,
		     void *cpu, mts_u64 dma)
{
	struct mts_packet_state *state = ctx;

	pr_info("unpublished-free slot=%u size=%zu dma=%016llx\n", slot, size,
		(unsigned long long)dma);
	dma_free_coherent(&state->gbe->dev, size, cpu, (dma_addr_t)dma);
}

static const struct mts_prepare_ops prepare_ops = {
	.alloc = mts_allocate,
	.free = mts_free,
};

static int mts_hex(char byte)
{
	if (byte >= '0' && byte <= '9')
		return byte - '0';
	if (byte >= 'a' && byte <= 'f')
		return byte - 'a' + 10;
	if (byte >= 'A' && byte <= 'F')
		return byte - 'A' + 10;
	return -EINVAL;
}

static int mts_make_frames(struct mts_packet_state *state)
{
	static const u8 source[6] = {0x02, 0x50, 0x53, 0x58, 0x00, 0x01};
	static const u8 peer[6] = {0x02, 0x50, 0x53, 0x58, 0x00, 0x02};
	unsigned int i;
	int high, low;

	if (!nonce || strlen(nonce) != 32)
		return -EINVAL;
	for (i = 0; i < sizeof(state->nonce_bytes); ++i) {
		high = mts_hex(nonce[i * 2]);
		low = mts_hex(nonce[i * 2 + 1]);
		if (high < 0 || low < 0)
			return -EINVAL;
		state->nonce_bytes[i] = (u8)((high << 4) | low);
	}
	memset(state->tx_frame, 0, sizeof(state->tx_frame));
	memset(state->rx_frame, 0, sizeof(state->rx_frame));
	memset(state->tx_frame, 0xff, 6);
	memset(state->rx_frame, 0xff, 6);
	memcpy(state->tx_frame + 6, source, 6);
	memcpy(state->rx_frame + 6, peer, 6);
	state->tx_frame[12] = state->rx_frame[12] = 0x88;
	state->tx_frame[13] = state->rx_frame[13] = 0xb5;
	memcpy(state->tx_frame + 14, "PSXTX1", 6);
	memcpy(state->rx_frame + 14, "PSXRX1", 6);
	memcpy(state->tx_frame + 20, state->nonce_bytes, 16);
	memcpy(state->rx_frame + 20, state->nonce_bytes, 16);
	return 0;
}

static void mts_initialize_memory(struct mts_packet_state *state)
{
	struct mts_descriptor *tx = state->memory.resource[MTS_PREPARE_TX_RING].cpu;
	struct mts_descriptor *rx = state->memory.resource[MTS_PREPARE_RX_RING].cpu;
	mts_u64 pool = state->memory.resource[MTS_PREPARE_RX_POOL].dma;
	unsigned int i;

	for (i = 0; i < MTS_PREPARE_SLOT_COUNT; ++i)
		memset(state->memory.resource[i].cpu, 0, state->memory.resource[i].size);
	for (i = 0; i < MTS_DESCRIPTOR_COUNT; ++i) {
		tx[i].word[0] = cpu_to_le32(mts_tx_idle_word0());
		tx[i].word[2] = cpu_to_le32(mts_tx_idle_word2());
		rx[i].word[0] = cpu_to_le32(mts_rx_initial_word0(i));
		rx[i].word[1] = cpu_to_le32((u32)(pool + i * MTS_RX_BUFFER_BYTES));
	}
	memset(state->tx_packet, 0, MTS_TX_PACKET_BYTES);
	memcpy(state->tx_packet, state->tx_frame, MTS_FRAME_BYTES);
}

static int mts_verify_memory(struct mts_packet_state *state)
{
	struct mts_descriptor *tx = state->memory.resource[MTS_PREPARE_TX_RING].cpu;
	struct mts_descriptor *rx = state->memory.resource[MTS_PREPARE_RX_RING].cpu;
	mts_u64 pool = state->memory.resource[MTS_PREPARE_RX_POOL].dma;
	unsigned int i;

	for (i = 0; i < MTS_DESCRIPTOR_COUNT; ++i) {
		if (le32_to_cpu(tx[i].word[0]) != mts_tx_idle_word0() ||
		    tx[i].word[1] || le32_to_cpu(tx[i].word[2]) != mts_tx_idle_word2() ||
		    tx[i].word[3] ||
		    le32_to_cpu(rx[i].word[0]) != mts_rx_initial_word0(i) ||
		    le32_to_cpu(rx[i].word[1]) != (u32)(pool + i * MTS_RX_BUFFER_BYTES) ||
		    rx[i].word[2] || rx[i].word[3])
			return -EIO;
	}
	if (memchr_inv((u8 *)tx + MTS_RING_INITIALIZED_BYTES, 0,
		       MTS_RING_BACKING_BYTES - MTS_RING_INITIALIZED_BYTES) ||
	    memchr_inv((u8 *)rx + MTS_RING_INITIALIZED_BYTES, 0,
		       MTS_RING_BACKING_BYTES - MTS_RING_INITIALIZED_BYTES) ||
	    memchr_inv(state->memory.resource[MTS_PREPARE_RX_POOL].cpu, 0,
		       MTS_RX_POOL_BYTES) ||
	    memcmp(state->tx_packet, state->tx_frame, MTS_FRAME_BYTES) ||
	    memchr_inv((u8 *)state->tx_packet + MTS_FRAME_BYTES, 0,
		       MTS_TX_PACKET_BYTES - MTS_FRAME_BYTES))
		return -EIO;
	return 0;
}

static void mts_cleanup_unpublished(struct mts_packet_state *state)
{
	/* All callers must be unpublished; retention deliberately has no inverse. */
	if (WARN_ON_ONCE(state->retained || state->published))
		return;
	if (state->tx_packet) {
		dma_free_coherent(&state->gbe->dev, MTS_TX_PACKET_BYTES,
				  state->tx_packet, state->tx_packet_dma);
		state->tx_packet = NULL;
	}
	mts_finish(&state->memory);
	if (state->function_mask) {
		pci_iounmap(state->glue, state->function_mask);
		state->function_mask = NULL;
	}
	if (state->mac) {
		pci_iounmap(state->gbe, state->mac);
		state->mac = NULL;
	}
	mts_unlock_devices(state);
	if (state->owner_held) {
		module_put(state->glue_owner);
		state->owner_held = false;
	}
	pci_dev_put(state->glue);
	pci_dev_put(state->gbe);
	state->glue = NULL;
	state->gbe = NULL;
	state->prepared = false;
}

static void mts_poll_packet(struct mts_packet_state *state)
{
	struct mts_descriptor *tx = state->memory.resource[MTS_PREPARE_TX_RING].cpu;
	struct mts_descriptor *rx = state->memory.resource[MTS_PREPARE_RX_RING].cpu;
	u8 *pool = state->memory.resource[MTS_PREPARE_RX_POOL].cpu;
	unsigned long deadline = jiffies + msecs_to_jiffies(MTS_PACKET_DEADLINE_MS);
	unsigned int i;
	u32 raw;
	size_t length;

	do {
		state->txd0 = le32_to_cpu(READ_ONCE(tx[0].word[0]));
		dma_rmb();
		state->txd2 = le32_to_cpu(READ_ONCE(tx[0].word[2]));
		if (mts_tx_is_complete(state->submitted, state->txd0, state->txd2))
			state->tx_completed = true;
		if (!state->rx_matched) {
			for (i = 0; i < MTS_DESCRIPTOR_COUNT; ++i) {
				raw = le32_to_cpu(READ_ONCE(rx[i].word[0]));
				if (!mts_rx_is_candidate(raw))
					continue;
				state->rxd0 = raw;
				state->rx_length = raw & 0x7ffu;
				state->rx_slot = i;
				if (!mts_rx_copy_length(raw, &length) || length < MTS_FRAME_BYTES)
					continue;
				dma_rmb();
				if (!memcmp(pool + i * MTS_RX_BUFFER_BYTES,
					    state->rx_frame, MTS_FRAME_BYTES)) {
					state->rx_matched = true;
					state->rx_length = length;
					break;
				}
			}
		}
		if (state->tx_completed && state->rx_matched)
			return;
		usleep_range(100, 200);
	} while (time_before(jiffies, deadline));
	state->error = -ETIMEDOUT;
}

static int mts_stop_retained(struct mts_packet_state *state)
{
	u32 polled;
	int error;

	/* Raw entry witnesses only: unknown read/W1C effects, no acknowledgement. */
	state->tx_reg3c_stop_entry = readl(state->mac + MTS_TX_RING_BASE);
	state->rx_reg40_stop_entry = readl(state->mac + MTS_RX_RING_BASE);
	state->status50_stop_entry = readl(state->mac + MTS_MAC_STATUS);
	state->stop_entry_sampled = true;
	state->tx_control = readl(state->mac + MTS_TX_CONTROL);
	state->tx_before_stop = state->tx_control;
	state->tx_before_stop_sampled = true;
	if (state->tx_control == 0xffffffff)
		return -EIO;
	writel(2, state->mac + MTS_TX_CONTROL);
	error = readl_poll_timeout(state->mac + MTS_TX_CONTROL, polled,
				   !(polled & BIT(1)), MTS_POLL_SLEEP_US,
				   MTS_STOP_DEADLINE_US);
	state->tx_control = polled;
	if (error) {
		pr_err("TX stop timeout last=%08x RX stop skipped; resources retained\n", polled);
		return error;
	}
	state->rx_control = readl(state->mac + MTS_RX_CONTROL);
	state->rx_before_stop_after_tx_stop = state->rx_control;
	state->rx_before_stop_after_tx_stop_sampled = true;
	if (state->rx_control == 0xffffffff)
		return -EIO;
	writel(2, state->mac + MTS_RX_CONTROL);
	error = readl_poll_timeout(state->mac + MTS_RX_CONTROL, polled,
				   !(polled & BIT(1)), MTS_POLL_SLEEP_US,
				   MTS_STOP_DEADLINE_US);
	state->rx_control = polled;
	if (error)
		return error;
	error = mts_revalidate(state, true);
	if (!error)
		state->stopack = true;
	return error;
}

static int mts_arm_set(const char *value, const struct kernel_param *parameter)
{
	struct mts_packet_state *state = &packet;
	struct mts_descriptor *tx;
	u32 control;
	int error;

	(void)parameter;
	/* Reject init-time module arguments before touching experiment state. */
	if (READ_ONCE(THIS_MODULE->state) != MODULE_STATE_LIVE ||
	    (strcmp(value, "1") && strcmp(value, "1\n")))
		return -EINVAL;
	if (!mutex_trylock(&action_mutex))
		return -EBUSY;
	if (!state->prepared || state->attempted || state->retained) {
		error = -EBUSY;
		goto unlock_action;
	}
	state->attempted = true;
	state->stage = "arm-locks";
	error = mts_trylock_devices(state);
	if (error)
		goto refused;
	state->stage = "arm-revalidate";
	error = mts_revalidate_link_baseline(state);
	if (error)
		goto refused;
	state->stage = "arm-dma-nonoverlap";
	error = mts_validate_dma_nonoverlap(state);
	if (error)
		goto refused;
	state->stage = "arm-memory-check";
	error = mts_verify_memory(state);
	if (error)
		goto refused;
	tx = state->memory.resource[MTS_PREPARE_TX_RING].cpu;
	tx[0].word[1] = cpu_to_le32((u32)state->tx_packet_dma);
	tx[0].word[2] = cpu_to_le32(0);
	tx[0].word[3] = cpu_to_le32(0);
	WRITE_ONCE(tx[0].word[0], cpu_to_le32(MTS_TX_FRAME_WORD0));
	if (READ_ONCE(THIS_MODULE->state) != MODULE_STATE_LIVE) {
		error = -EBUSY;
		goto refused;
	}
	/* Irreversible self-pin precedes every possible device-visible address. */
	if (!try_module_get(THIS_MODULE)) {
		error = -EBUSY;
		goto refused;
	}
	state->retained = true;
	state->published = true;
	state->stage = "publish-rings";
	dma_wmb();
	writel((u32)state->memory.resource[MTS_PREPARE_TX_RING].dma,
	       state->mac + MTS_TX_RING_CURSOR);
	writel((u32)state->memory.resource[MTS_PREPARE_TX_RING].dma,
	       state->mac + MTS_TX_RING_BASE);
	writel((u32)state->memory.resource[MTS_PREPARE_RX_RING].dma,
	       state->mac + MTS_RX_RING_CURSOR);
	writel((u32)state->memory.resource[MTS_PREPARE_RX_RING].dma,
	       state->mac + MTS_RX_RING_BASE);
	state->stage = "enable-tx-rx";
	control = readl(state->mac + MTS_TX_CONTROL);
	state->tx_before_enable = control;
	state->tx_before_enable_sampled = true;
	if (control == 0xffffffff) {
		state->error = -EIO;
		goto stop;
	}
	writel(control | BIT(0), state->mac + MTS_TX_CONTROL);
	control = readl(state->mac + MTS_RX_CONTROL);
	state->rx_before_enable = control;
	state->rx_before_enable_sampled = true;
	if (control == 0xffffffff) {
		state->error = -EIO;
		goto stop;
	}
	writel(control | BIT(0), state->mac + MTS_RX_CONTROL);
	state->stage = "submit-one-frame";
	dma_wmb();
	state->submitted = true;
	WRITE_ONCE(tx[0].word[0], cpu_to_le32(MTS_TX_FRAME_WORD0 & ~(u32)BIT(31)));
	control = readl(state->mac + MTS_TX_CONTROL);
	state->tx_before_kick = control;
	state->tx_before_kick_sampled = true;
	if (control == 0xffffffff) {
		state->error = -EIO;
		goto stop;
	}
	writel(control | BIT(2), state->mac + MTS_TX_CONTROL);
	state->tx_after_kick = readl(state->mac + MTS_TX_CONTROL);
	state->tx_after_kick_sampled = true;
	if (state->tx_after_kick == 0xffffffff) {
		state->error = -EIO;
		goto stop;
	}
	state->stage = "poll-one-frame";
	mts_poll_packet(state);
stop:
	state->stage = "stop-retain";
	state->stop_error = mts_stop_retained(state);
	if (state->stop_error && !state->error)
		state->error = state->stop_error;
	state->stage = "retained";
	pr_info("RETAINED nonce=%s submitted=%u tx_completed=%u rx_matched=%u txd0=%08x txd2=%08x rxd0=%08x rx_slot=%u rx_length=%zu stopack=%u error=%d stop_error=%d published=%u drain=unproven\n",
		nonce, state->submitted, state->tx_completed, state->rx_matched,
		state->txd0, state->txd2, state->rxd0, state->rx_slot,
		state->rx_length, state->stopack, state->error, state->stop_error,
		state->published);
	pr_info("TRACE nonce=%s tx_before_enable_sampled=%u tx_before_enable=%08x rx_before_enable_sampled=%u rx_before_enable=%08x tx_before_kick_sampled=%u tx_before_kick=%08x tx_after_kick_sampled=%u tx_after_kick=%08x stop_entry_sampled=%u tx_reg3c_stop_entry=%08x rx_reg40_stop_entry=%08x status50_stop_entry=%08x tx_before_stop_sampled=%u tx_before_stop=%08x rx_before_stop_after_tx_stop_sampled=%u rx_before_stop_after_tx_stop=%08x interpretation=unknown drain=unproven\n",
		nonce,
		state->tx_before_enable_sampled, state->tx_before_enable,
		state->rx_before_enable_sampled, state->rx_before_enable,
		state->tx_before_kick_sampled, state->tx_before_kick,
		state->tx_after_kick_sampled, state->tx_after_kick,
		state->stop_entry_sampled, state->tx_reg3c_stop_entry,
		state->rx_reg40_stop_entry, state->status50_stop_entry,
		state->tx_before_stop_sampled, state->tx_before_stop,
		state->rx_before_stop_after_tx_stop_sampled,
		state->rx_before_stop_after_tx_stop);
	mts_unlock_devices(state);
	mutex_unlock(&action_mutex);
	/* A packet/stop timeout is a completed retained attempt, not an unload. */
	return 0;
refused:
	state->error = error;
	pr_err("arm refused stage=%s error=%d addresses-published=0 attempt-consumed=1\n",
	       state->stage, error);
	mts_unlock_devices(state);
unlock_action:
	mutex_unlock(&action_mutex);
	return error;
}

static int mts_report_get(char *buffer, const struct kernel_param *parameter)
{
	struct mts_packet_state *state = &packet;
	int length;

	(void)parameter;
	mutex_lock(&action_mutex);
	length = scnprintf(buffer, PAGE_SIZE,
		"state=%s stage=%s attempted=%u published=%u submitted=%u tx_completed=%u rx_matched=%u txd0=%08x txd2=%08x rxd0=%08x rx_slot=%u rx_length=%zu tx_control=%08x rx_control=%08x mac_mask=%08x routing_gate=%08x stopack=%u error=%d stop_error=%d nonce=%s tx_before_enable_sampled=%u tx_before_enable=%08x rx_before_enable_sampled=%u rx_before_enable=%08x tx_before_kick_sampled=%u tx_before_kick=%08x tx_after_kick_sampled=%u tx_after_kick=%08x stop_entry_sampled=%u tx_reg3c_stop_entry=%08x rx_reg40_stop_entry=%08x status50_stop_entry=%08x tx_before_stop_sampled=%u tx_before_stop=%08x rx_before_stop_after_tx_stop_sampled=%u rx_before_stop_after_tx_stop=%08x drain=unproven\n",
		state->retained ? "retained" : state->prepared ? "prepared" : "unprepared",
		state->stage ? state->stage : "none", state->attempted,
		state->published, state->submitted, state->tx_completed,
		state->rx_matched, state->txd0, state->txd2, state->rxd0,
		state->rx_slot, state->rx_length, state->tx_control,
		state->rx_control, state->mac_mask, state->routing_gate,
		state->stopack, state->error, state->stop_error, nonce ? nonce : "none",
		state->tx_before_enable_sampled, state->tx_before_enable,
		state->rx_before_enable_sampled, state->rx_before_enable,
		state->tx_before_kick_sampled, state->tx_before_kick,
		state->tx_after_kick_sampled, state->tx_after_kick,
		state->stop_entry_sampled, state->tx_reg3c_stop_entry,
		state->rx_reg40_stop_entry, state->status50_stop_entry,
		state->tx_before_stop_sampled, state->tx_before_stop,
		state->rx_before_stop_after_tx_stop_sampled,
		state->rx_before_stop_after_tx_stop);
	length += scnprintf(buffer + length, PAGE_SIZE - length,
		"phy_ctrl1_baseline=%08x dma_nonoverlap_checked=%u tx_ring_dma=%016llx tx_ring_bytes=%zu rx_ring_dma=%016llx rx_ring_bytes=%zu rx_pool_dma=%016llx rx_pool_bytes=%zu tx_packet_dma=%016llx tx_packet_bytes=%u original_override=%s mixed_generation_handoff=unproven\n",
		state->phy_ctrl1_baseline, state->dma_nonoverlap_checked,
		(unsigned long long)state->memory.resource[MTS_PREPARE_TX_RING].dma,
		state->memory.resource[MTS_PREPARE_TX_RING].size,
		(unsigned long long)state->memory.resource[MTS_PREPARE_RX_RING].dma,
		state->memory.resource[MTS_PREPARE_RX_RING].size,
		(unsigned long long)state->memory.resource[MTS_PREPARE_RX_POOL].dma,
		state->memory.resource[MTS_PREPARE_RX_POOL].size,
		(unsigned long long)state->tx_packet_dma, MTS_TX_PACKET_BYTES, MTS_OVERRIDE);
	mutex_unlock(&action_mutex);
	return length;
}

static const struct kernel_param_ops arm_ops = {.set = mts_arm_set};
static const struct kernel_param_ops report_ops = {.get = mts_report_get};
module_param_cb(arm, &arm_ops, NULL, 0200);
MODULE_PARM_DESC(arm, "Root-only one-shot: write 1 after init; publication permanently retains module/resources");
module_param_cb(report, &report_ops, NULL, 0400);
MODULE_PARM_DESC(report, "Cached one-shot results; stopack never establishes transaction drain");

static int __init psx_mts_packet_link_init(void)
{
	struct mts_packet_state *state = &packet;
	struct mts_prepare_status preparation;
	u16 gbe_command = 0;
	unsigned int i;
	int error = -EINVAL;

	static_assert(sizeof(struct mts_descriptor) == MTS_DESCRIPTOR_BYTES);
	state->stage = "kernel-release";
	pr_info("init kernel=%s one-shot-packet addresses-published=0\n", init_utsname()->release);
	if (strcmp(init_utsname()->release, MTS_RELEASE))
		goto fail;
	state->stage = "nonce";
	error = mts_make_frames(state);
	if (error)
		goto fail;
	state->stage = "device-references";
	state->gbe = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(MTS_SLOT, 1));
	state->glue = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(MTS_SLOT, 4));
	if (!state->gbe || !state->glue) {
		error = -ENODEV;
		goto fail;
	}
	state->stage = "device-trylocks";
	error = mts_trylock_devices(state);
	if (error)
		goto fail;
	state->stage = "cached-metadata-direct-dma";
	error = mts_metadata(state);
	if (error)
		goto fail;
	state->glue_driver = state->glue->dev.driver;
	state->glue_owner = state->glue_driver->owner;
	if (state->glue_owner) {
		if (!try_module_get(state->glue_owner)) {
			error = -ENODEV;
			goto fail;
		}
		state->owner_held = true;
	}
	state->stage = "pci-command-capabilities";
	error = mts_read_commands(state, &gbe_command, &state->glue_command);
	if (error)
		goto fail;
	error = mts_read_disabled_caps(state->gbe, &state->caps);
	if (error)
		goto fail;
	mts_snapshot_bar(state->gbe, 0, &state->gbe_bar);
	mts_snapshot_bar(state->glue, 2, &state->glue_bar);
	state->stage = "bar-layout";
	if ((state->gbe_bar.flags & IORESOURCE_TYPE_BITS) != IORESOURCE_MEM ||
	    state->gbe_bar.start != 0xc2000000ULL || state->gbe_bar.length != 0x1000 ||
	    (state->glue_bar.flags & IORESOURCE_TYPE_BITS) != IORESOURCE_MEM ||
	    state->glue_bar.start != 0xc8800000ULL || state->glue_bar.length != 0x200000) {
		error = -EINVAL;
		goto fail;
	}
	/* The sealed runner verifies the original owner's claim; never acquire/release it. */
	state->stage = "minimal-mappings";
	state->mac = pci_iomap_range(state->gbe, 0, 0, MTS_MAC_MAP_BYTES);
	state->function_mask = pci_iomap_range(state->glue, 2,
					    MTS_FUNC1_MASK_OFFSET, sizeof(u32));
	if (!state->mac || !state->function_mask) {
		error = -ENOMEM;
		goto fail;
	}
	state->stage = "stopped-gate-baseline";
	error = mts_read_link_baseline(state);
	if (error)
		goto fail;
	state->stage = "prepare-three-resources";
	preparation = mts_prepare(&state->memory, &prepare_ops, state);
	if (preparation.result != MTS_PREPARE_OK) {
		pr_err("prepare result=%u failing-slot=%u\n", preparation.result, preparation.slot);
		error = -ENOMEM;
		goto fail;
	}
	state->stage = "prepare-tx-packet";
	state->tx_packet = dma_alloc_coherent(&state->gbe->dev, MTS_TX_PACKET_BYTES,
					     &state->tx_packet_dma,
					     GFP_KERNEL | __GFP_NOWARN | __GFP_NORETRY);
	if (!state->tx_packet) {
		error = -ENOMEM;
		goto fail;
	}
	if (!mts_dma_extent_valid((mts_u64)state->tx_packet_dma, MTS_TX_PACKET_BYTES)) {
		error = -ERANGE;
		goto fail;
	}
	state->stage = "fresh-old-dma-nonoverlap";
	error = mts_validate_dma_nonoverlap(state);
	if (error)
		goto fail;
	state->stage = "initialize-verify";
	mts_initialize_memory(state);
	error = mts_verify_memory(state);
	if (error)
		goto fail;
	error = mts_revalidate_link_baseline(state);
	if (error)
		goto fail;
	for (i = 0; i < MTS_PREPARE_SLOT_COUNT; ++i)
		pr_info("prepared slot=%u dma=%016llx bytes=%zu end=%016llx\n", i,
			(unsigned long long)state->memory.resource[i].dma,
			state->memory.resource[i].size,
			(unsigned long long)(state->memory.resource[i].dma +
					     state->memory.resource[i].size - 1));
	pr_info("prepared TX-packet dma=%016llx bytes=%u end=%016llx\n",
		(unsigned long long)state->tx_packet_dma, MTS_TX_PACKET_BYTES,
		(unsigned long long)state->tx_packet_dma + MTS_TX_PACKET_BYTES - 1);
	state->prepared = true;
	state->stage = "prepared";
	mts_unlock_devices(state);
	pr_info("PREPARED nonce=%s command=%04x glue-command=%04x MSI@%x=%04x MSIX@%x=%04x routing-gate=%08x TX=%08x RX=%08x MACmask=%08x addresses-published=0 arm-required=1\n",
		nonce, gbe_command, state->glue_command, state->caps.msi_pos,
		state->caps.msi_flags, state->caps.msix_pos, state->caps.msix_flags,
		state->routing_gate, state->tx_control, state->rx_control, state->mac_mask);
	return 0;
fail:
	state->error = error;
	pr_err("init refused stage=%s error=%d addresses-published=0\n", state->stage, error);
	mts_cleanup_unpublished(state);
	return error;
}

static void __exit psx_mts_packet_link_exit(void)
{
	mutex_lock(&action_mutex);
	if (packet.retained || packet.published) {
		pr_emerg("forced unload unsupported: published DMA resources deliberately retained; power-cycle required\n");
		mutex_unlock(&action_mutex);
		return;
	}
	mts_cleanup_unpublished(&packet);
	mutex_unlock(&action_mutex);
	pr_info("unarmed unload completed addresses-published=0\n");
}

module_init(psx_mts_packet_link_init);
module_exit(psx_mts_packet_link_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Meerzulee and Linux psX contributors");
MODULE_DESCRIPTION("Same-boot original-order Baikal packet candidate after measured link restoration; retains both DMA generations");
