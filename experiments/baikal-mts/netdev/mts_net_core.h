/* SPDX-License-Identifier: GPL-2.0-only */
/* Original portable contracts; no firmware code or kernel I/O. */
#ifndef MTS_NET_CORE_H
#define MTS_NET_CORE_H

#ifdef __KERNEL__
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

#define MTS_SLOTS 256u
#define MTS_BUFFER_BYTES 0x600u
#define MTS_RING_BYTES 0x4000u
#define MTS_POOL_BYTES (MTS_SLOTS * MTS_BUFFER_BYTES)
#define MTS_COWN 0x80000000u
#define MTS_EOR 0x40000000u
#define MTS_FS 0x20000000u
#define MTS_LS 0x10000000u
#define MTS_RX_CRC 0x01000000u /* STAR reference; conservative Sony filter. */
#define MTS_RX_OVERSIZE 0x02000000u /* STAR reference; conservative filter. */
#define MTS_RX_VLAN 0x00100000u /* Native252ece VLAN metadata indication. */
#define MTS_TX_SENTINEL 0xffff0000u
#define MTS_IDLE_STOP_MASK 0x007ffffau
#define MTS_IDLE_HANDOFF_MASK 0x00001018u

static inline bool mts_idle_mask_matches(bool fresh, mts_u32 mask)
{
	return mask == MTS_IDLE_STOP_MASK ||
		(fresh && mask == MTS_IDLE_HANDOFF_MASK);
}

static inline bool mts_extent_valid(mts_u64 dma, size_t size)
{
	return size && dma <= 0xffffffffULL &&
		(mts_u64)(size - 1) <= 0xffffffffULL - dma;
}

/* Call only with validated, nonempty extents. */
static inline bool mts_extent_overlap(mts_u64 a, size_t as,
				      mts_u64 b, size_t bs)
{
	return a <= b + bs - 1 && b <= a + as - 1;
}

static inline unsigned int mts_next(unsigned int slot)
{
	return (slot + 1u) & (MTS_SLOTS - 1u);
}

static inline mts_u32 mts_tx_idle(unsigned int slot)
{
	return MTS_COWN | (slot == MTS_SLOTS - 1 ? MTS_EOR : 0);
}

static inline mts_u32 mts_tx_ready(unsigned int slot, unsigned int length)
{
	return mts_tx_idle(slot) | MTS_FS | MTS_LS | length;
}

static inline mts_u32 mts_rx_ready(unsigned int slot)
{
	return MTS_BUFFER_BYTES | (slot == MTS_SLOTS - 1 ? MTS_EOR : 0);
}

static inline bool mts_tx_complete(bool submitted, mts_u32 d0, mts_u32 d2)
{
	return submitted && (d0 & MTS_COWN) && d2 <= 0xfffeffffu;
}

enum mts_rx_result {
	MTS_RX_NOT_OWNED, MTS_RX_BAD_LENGTH, MTS_RX_FRAGMENT,
	MTS_RX_BAD_CRC, MTS_RX_TOO_LARGE, MTS_RX_TAGGED, MTS_RX_ACCEPT
};

/* No FCS subtraction. Length/OWN are native; stricter filters are explicit. */
static inline enum mts_rx_result mts_rx_classify(mts_u32 d0,
						unsigned int *length)
{
	*length = d0 & 0x7ffu;
	if (!(d0 & MTS_COWN))
		return MTS_RX_NOT_OWNED;
	if (*length < 14u || *length > MTS_BUFFER_BYTES)
		return MTS_RX_BAD_LENGTH;
	if ((d0 & (MTS_FS | MTS_LS)) != (MTS_FS | MTS_LS))
		return MTS_RX_FRAGMENT;
	if (d0 & MTS_RX_CRC)
		return MTS_RX_BAD_CRC;
	if (d0 & MTS_RX_OVERSIZE)
		return MTS_RX_TOO_LARGE;
	if (d0 & MTS_RX_VLAN)
		return MTS_RX_TAGGED;
	return MTS_RX_ACCEPT;
}

/* Caller serializes this software ledger with the descriptor producer/consumer. */
struct mts_tx_ledger {
	unsigned int head, tail, count;
	unsigned int length[MTS_SLOTS];
	bool submitted[MTS_SLOTS];
};

static inline bool mts_tx_reserve(struct mts_tx_ledger *q, unsigned int length,
				 unsigned int *slot)
{
	if (!length || length > MTS_BUFFER_BYTES || q->count >= MTS_SLOTS ||
	    q->submitted[q->head])
		return false;
	*slot = q->head;
	q->length[*slot] = length;
	q->submitted[*slot] = true;
	q->head = mts_next(q->head);
	q->count++;
	return true;
}

static inline bool mts_tx_retire(struct mts_tx_ledger *q, mts_u32 d0,
				mts_u32 d2, unsigned int *bytes)
{
	unsigned int slot = q->tail;
	if (!q->count || !mts_tx_complete(q->submitted[slot], d0, d2))
		return false;
	*bytes = q->length[slot];
	q->submitted[slot] = false;
	q->length[slot] = 0;
	q->tail = mts_next(slot);
	q->count--;
	return true;
}
#endif
