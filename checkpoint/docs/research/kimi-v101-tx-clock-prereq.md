# v101 — TX clock enable prerequisite

**kimi-k2.6, 2026-05-13**

## Diagnosis

BAR+0x06c bit 9 is **hardware-gated**: writes to `0x300` read back as `0x100`, meaning the TX clock/FIFO enable cannot be asserted until an upstream prerequisite is satisfied. RX bit 8 is already set and works.

## Prime suspect: TX FIFO threshold (0x05c)

Current `0x05c = 0x00101000` (bits 12 and 20). In MAC designs, the TX clock gate is frequently **write-once** after FIFO depth/threshold is programmed. If the FIFO watermark is unset or at POR default, the hardware rejects the TX clock enable to prevent underrun.

**Test**: Write `0x00101000` explicitly to `0x05c` (or try `0x001f03ff` copied from `0x0b0`), then attempt `0x300` at `0x06c`.

## Secondary suspect: BAR+0x080 mode register

Current `0x080 = 0x2bb`. Bits 0, 1, 3, 4, 5, 7, 9 are set. If this register controls MAC operating mode, a missing TX mode bit (e.g., bit 2, 6, or 10) could lock the TX clock.

**Test**: Try `0x3bb` (bit 8 set), `0x2fb` (bit 6 set), or `0x6bb` (bit 10 set), then re-test `0x06c`.

## Tertiary: reset-toggle sequence via 0x064

Current `0x064 = 0x6` (bits 1+2). Some MACs require a **clear-then-set** of a companion reset register before the clock enable becomes writable:
1. Write `0x4` to `0x064` (clear bit 1)
2. Write `0x300` to `0x06c`
3. Write `0x6` to `0x064` (re-assert bit 1)
4. Read back `0x06c`

## Least likely

- **0x070 (0x10003)**: Pause/flow control — would affect link behavior, not gate the clock enable itself.
- **0x078 (0)**: RX_GATE is RX-specific; no evidence of TX gate at this offset.

## Recommended test order

1. Explicit write to `0x05c` → `0x06c = 0x300`
2. If fail: try `0x080 = 0x3bb/0x2fb/0x6bb` → `0x06c`
3. If fail: try 0x064 toggle sequence → `0x06c`
