/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (C) 2026 Meerzulee and Linux psX contributors */
#ifndef PSX_MTS_PREPARE_H
#define PSX_MTS_PREPARE_H

#ifdef __KERNEL__
#include <linux/stddef.h>
#include <linux/types.h>
typedef u32 mts_u32;
typedef u64 mts_u64;
#else
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t mts_u32;
typedef uint64_t mts_u64;
#endif

#define MTS_DESCRIPTOR_COUNT 256u
#define MTS_DESCRIPTOR_BYTES 16u
#define MTS_RING_BACKING_BYTES 0x4000u
#define MTS_RING_INITIALIZED_BYTES 0x1000u
#define MTS_RING_DMA_ALIGNMENT 0x4000u
#define MTS_RX_BUFFER_BYTES 0x600u
#define MTS_RX_POOL_BYTES 0x60000u
#define MTS_DMA_MAX_ADDRESS ((mts_u64)0xffffffffu)

enum mts_prepare_slot {
	MTS_PREPARE_TX_RING = 0,
	MTS_PREPARE_RX_RING,
	MTS_PREPARE_RX_POOL,
	MTS_PREPARE_SLOT_COUNT,
	MTS_PREPARE_NO_SLOT = MTS_PREPARE_SLOT_COUNT,
};

enum mts_prepare_result {
	MTS_PREPARE_OK = 0,
	MTS_PREPARE_BAD_ARGUMENT,
	MTS_PREPARE_BUSY,
	MTS_PREPARE_ALLOCATION_FAILED,
	MTS_PREPARE_DMA_RANGE,
	MTS_PREPARE_DMA_ALIGNMENT,
};

struct mts_prepare_status {
	enum mts_prepare_result result;
	enum mts_prepare_slot slot;
};

struct mts_prepare_ops {
	void *(*alloc)(void *ctx, enum mts_prepare_slot slot, size_t size,
		       mts_u64 *dma);
	void (*free)(void *ctx, enum mts_prepare_slot slot, size_t size,
		     void *cpu, mts_u64 dma);
};

struct mts_prepare_resource {
	void *cpu;
	mts_u64 dma;
	size_t size;
};

/* Zero-initialize before first use. Only this core changes ownership fields. */
struct mts_prepared {
	struct mts_prepare_resource resource[MTS_PREPARE_SLOT_COUNT];
	struct mts_prepare_ops ops;
	void *ctx;
};

/* Inclusive full-extent validation, without computing dma + size. */
static inline bool mts_dma_extent_valid(mts_u64 dma, size_t size)
{
	if (!size || dma > MTS_DMA_MAX_ADDRESS)
		return false;
	return size - 1u <= MTS_DMA_MAX_ADDRESS - dma;
}

static inline size_t mts_prepare_slot_size(enum mts_prepare_slot slot)
{
	return slot == MTS_PREPARE_RX_POOL ? MTS_RX_POOL_BYTES :
		MTS_RING_BACKING_BYTES;
}

/* Release only owned pointers, in reverse order; repeated calls are no-ops. */
static inline void mts_finish(struct mts_prepared *state)
{
	unsigned int index;

	if (!state)
		return;
	for (index = MTS_PREPARE_SLOT_COUNT; index > 0; index--) {
		struct mts_prepare_resource *resource = &state->resource[index - 1u];
		void *cpu = resource->cpu;
		mts_u64 dma = resource->dma;
		size_t size = resource->size;

		/* Relinquish ownership before entering the caller's free callback. */
		resource->cpu = NULL;
		resource->dma = 0;
		resource->size = 0;
		if (cpu)
			state->ops.free(state->ctx,
				(enum mts_prepare_slot)(index - 1u), size, cpu, dma);
	}
	state->ops.alloc = NULL;
	state->ops.free = NULL;
	state->ctx = NULL;
}

static inline struct mts_prepare_status
mts_prepare(struct mts_prepared *state, const struct mts_prepare_ops *ops,
	    void *ctx)
{
	struct mts_prepare_status status = {
		MTS_PREPARE_BAD_ARGUMENT, MTS_PREPARE_NO_SLOT,
	};
	unsigned int index;

	if (!state || !ops || !ops->alloc || !ops->free)
		return status;
	for (index = 0; index < MTS_PREPARE_SLOT_COUNT; index++) {
		if (state->resource[index].cpu) {
			status.result = MTS_PREPARE_BUSY;
			status.slot = (enum mts_prepare_slot)index;
			return status;
		}
	}

	/* Save matching callbacks and context, not a borrowed ops pointer. */
	state->ops = *ops;
	state->ctx = ctx;
	for (index = 0; index < MTS_PREPARE_SLOT_COUNT; index++) {
		enum mts_prepare_slot slot = (enum mts_prepare_slot)index;
		struct mts_prepare_resource *resource = &state->resource[index];

		status.slot = slot;
		resource->size = mts_prepare_slot_size(slot);
		resource->dma = 0;
		resource->cpu = state->ops.alloc(ctx, slot, resource->size,
						&resource->dma);
		if (!resource->cpu) {
			status.result = MTS_PREPARE_ALLOCATION_FAILED;
			goto fail;
		}
		/* The returned pointer is owned even if its DMA handle is invalid. */
		if (!mts_dma_extent_valid(resource->dma, resource->size)) {
			status.result = MTS_PREPARE_DMA_RANGE;
			goto fail;
		}
		if (slot != MTS_PREPARE_RX_POOL &&
		    resource->dma % MTS_RING_DMA_ALIGNMENT != 0) {
			status.result = MTS_PREPARE_DMA_ALIGNMENT;
			goto fail;
		}
	}
	status.result = MTS_PREPARE_OK;
	status.slot = MTS_PREPARE_NO_SLOT;
	return status;

fail:
	mts_finish(state);
	return status;
}

/* Native-value helpers only; the wrapper owns little-endian memory writes. */
static inline mts_u32 mts_tx_idle_word0(void)
{
	return 0x80000000u;
}

static inline mts_u32 mts_tx_idle_word2(void)
{
	return 0xffff0000u;
}

static inline mts_u32 mts_rx_initial_word0(unsigned int slot)
{
	return MTS_RX_BUFFER_BYTES |
		(slot == MTS_DESCRIPTOR_COUNT - 1u ? 0x40000000u : 0u);
}

static inline bool mts_tx_is_complete(bool submitted, mts_u32 word0,
				     mts_u32 word2)
{
	return submitted && (word0 & 0x80000000u) != 0 && word2 <= 0xfffeffffu;
}

static inline bool mts_rx_is_candidate(mts_u32 word0)
{
	return word0 >= 0x80000001u;
}

/* This bounds a prospective copy only; it does not validate frame status. */
static inline bool mts_rx_copy_length(mts_u32 word0, size_t *length_out)
{
	size_t length;

	if (!length_out)
		return false;
	*length_out = 0;
	if (!mts_rx_is_candidate(word0))
		return false;
	length = word0 & 0x7ffu;
	if (!length || length > MTS_RX_BUFFER_BYTES)
		return false;
	*length_out = length;
	return true;
}

#endif /* PSX_MTS_PREPARE_H */
