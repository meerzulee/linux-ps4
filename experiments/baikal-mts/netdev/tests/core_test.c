/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "mts_net_core.h"

static void extent_test(void)
{
	assert(mts_extent_valid(0, MTS_RING_BYTES));
	assert(mts_extent_valid(0xffffc000ULL, MTS_RING_BYTES));
	assert(!mts_extent_valid(0xffffc001ULL, MTS_RING_BYTES));
	assert(mts_extent_valid(0xffffffffULL, 1));
	assert(!mts_extent_valid(0xffffffffULL, 2));
	assert(!mts_extent_valid(0x100000000ULL, 1));
	assert(!mts_extent_valid(UINT64_MAX, 0x4000));
	assert(!mts_extent_valid(1, SIZE_MAX));
	assert(!mts_extent_valid(0, 0));
	assert(!mts_extent_overlap(0, 0x4000, 0x4000, 0x4000));
	assert(mts_extent_overlap(0, 0x4000, 0x3fff, 1));
	assert(mts_extent_overlap(0x10000, 0x60000, 0x20000, 0x4000));
	assert(mts_extent_overlap(0x20000, 0x4000, 0x10000, 0x60000));
	assert(!mts_extent_overlap(0xffffc000ULL, 0x4000, 0, 0x60000));
}

static void descriptor_test(void)
{
	unsigned int length, i;
	for (i = 0; i < MTS_SLOTS; ++i) {
		assert(mts_tx_idle(i) == (i == 255 ? 0xc0000000u : 0x80000000u));
		assert(mts_rx_ready(i) == (i == 255 ? 0x40000600u : 0x600u));
	}
	assert(mts_tx_ready(0, 60) == 0xb000003cu);
	assert(mts_tx_ready(255, 60) == 0xf000003cu);
	assert(!mts_tx_complete(false, 0xb000003c, 0));
	assert(!mts_tx_complete(true, 0x3000003c, 0));
	assert(!mts_tx_complete(true, 0x80000000, 0xffff0000));
	assert(!mts_tx_complete(true, 0xb000003c, 0xffffffff));
	assert(mts_tx_complete(true, 0xb000003c, 0xfffeffff));
	assert(mts_tx_complete(true, 0xb000003c, 0));
	assert(mts_rx_classify(0x600, &length) == MTS_RX_NOT_OWNED);
	assert(mts_rx_classify(0x80000000, &length) == MTS_RX_BAD_LENGTH);
	assert(mts_rx_classify(0x80000001, &length) == MTS_RX_BAD_LENGTH);
	assert(mts_rx_classify(0xb000000d, &length) == MTS_RX_BAD_LENGTH);
	assert(mts_rx_classify(0xb000000e, &length) == MTS_RX_ACCEPT && length == 14);
	assert(mts_rx_classify(0xb0000600, &length) == MTS_RX_ACCEPT && length == 1536);
	assert(mts_rx_classify(0xb0000601, &length) == MTS_RX_BAD_LENGTH);
	assert(mts_rx_classify(0xb00007ff, &length) == MTS_RX_BAD_LENGTH);
	assert(mts_rx_classify(0x8000003c, &length) == MTS_RX_FRAGMENT);
	assert(mts_rx_classify(0x9000003c, &length) == MTS_RX_FRAGMENT);
	assert(mts_rx_classify(0xa000003c, &length) == MTS_RX_FRAGMENT);
	assert(mts_rx_classify(0xb100003c, &length) == MTS_RX_BAD_CRC);
	assert(mts_rx_classify(0xb200003c, &length) == MTS_RX_TOO_LARGE);
	assert(mts_rx_classify(0xb010003c, &length) == MTS_RX_TAGGED);
	/* Actual 60-byte EXP013 peer reply; never subtract a guessed FCS. */
	assert(mts_rx_classify(0xb40c003c, &length) == MTS_RX_ACCEPT && length == 60);
	assert(mts_rx_classify(0xb004014c, &length) == MTS_RX_ACCEPT && length == 332);
	assert(mts_rx_classify(0xf40c003c, &length) == MTS_RX_ACCEPT && length == 60);
}

static void idle_mask_test(void)
{
	/* Two measured fresh idle handoffs; normalized state remains exact. */
	assert(mts_idle_mask_matches(true, 0x1018));
	assert(mts_idle_mask_matches(true, 0x7ffffa));
	assert(mts_idle_mask_matches(false, 0x7ffffa));
	assert(!mts_idle_mask_matches(false, 0x1018));
	assert(!mts_idle_mask_matches(true, 0));
	assert(!mts_idle_mask_matches(true, 0xffffffff));
	assert(!mts_idle_mask_matches(true, 0x1019));
	assert(!mts_idle_mask_matches(true, 0x7ffffb));
}

static void ledger_test(void)
{
	struct mts_tx_ledger q = {0};
	unsigned int slot = 999, bytes = 999, i, pass;
	unsigned long long sent = 0, completed = 0;
	assert(!mts_tx_retire(&q, 0xb000003c, 0, &bytes));
	assert(!mts_tx_reserve(&q, 0, &slot));
	assert(!mts_tx_reserve(&q, 1537, &slot));
	/* Two full wraps with varying per-slot bytes model exact BQL pairing. */
	for (pass = 0; pass < 3; pass++) {
		for (i = 0; i < MTS_SLOTS; i++) {
			unsigned int length = 60 + i;
			assert(mts_tx_reserve(&q, length, &slot));
			assert(slot == i && q.submitted[i]);
			sent += length;
		}
		assert(q.count == MTS_SLOTS && q.head == q.tail);
		assert(!mts_tx_reserve(&q, 60, &slot));
		assert(!mts_tx_retire(&q, 0x3000003c, 0, &bytes));
		assert(q.count == MTS_SLOTS);
		assert(!mts_tx_retire(&q, 0xb000003c, MTS_TX_SENTINEL, &bytes));
		for (i = 0; i < MTS_SLOTS; i++) {
			assert(q.tail == i);
			assert(mts_tx_retire(&q, mts_tx_ready(i, 60 + i), 0, &bytes));
			assert(bytes == 60 + i && !q.submitted[i] && q.length[i] == 0);
			completed += bytes;
		}
		assert(q.count == 0 && q.head == 0 && q.tail == 0);
		assert(!mts_tx_retire(&q, 0xb000003c, 0, &bytes));
	}
	assert(sent == completed);
	/* Corrupt ledger admission fails rather than overwriting an in-flight slot. */
	q.submitted[q.head] = true;
	assert(!mts_tx_reserve(&q, 60, &slot));
}

int main(void)
{
	extent_test();
	descriptor_test();
	idle_mask_test();
	ledger_test();
	puts("PASS extent bounds/nonoverlap, native descriptors/conservative RX, idle handoff masks, TX ledger/3 wraps/BQL bytes");
	return 0;
}
