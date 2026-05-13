# v101: What sets bit 9 of BAR+0x06c -- no explicit write exists, it is a hardware status bit

## Finding

No Orbis function explicitly writes BAR+0x06c. Decompilation of msk_init_hw,
mts_mac_init, mts_init_rings_kick, gbe:ctrl thread, and the ioctl handler
all confirms: **0x06c is never a write target**. Bit 9 (0x200) is a
hardware-auto-set status flag, not a driver-programmed bit.

## What the live test tells us

- BAR+0x06c reads 0x100 (bit 8 set)
- Writing 0x300 (bits 8+9): readback 0x100 -- bit 9 rejected (RO)
- Clearing BAR+0x064 first then writing 0x300: still readback 0x100
- Bit 8 is RW (we can toggle it), bit 9 is RO-status (HW sets it when ready)

## What could trigger bit 9 to auto-set

Since no driver writes 0x06c, bit 9 is a **consequence bit** -- it gets set
by hardware when some precondition is satisfied. In Yukon-2 (sky2), the
PREF_UNIT_CTRL OP_ON status is reflected in Q_CSR bits. On Baikal MTS,
the analogous TX-DMA-ready flag lives at 0x06c bit 9.

The Orbis sequences that happen BEFORE any TX activity and that we skip or
partially skip:

1. **BAR+0x074 = 0x2277** (mts_mac_init) -- TX FIFO watermark. sky2
   requires Q_WM = 0x600 before PREF_UNIT_OP_ON. This is the strongest
   candidate: without watermark, the TX FIFO may refuse to drain
   descriptors, which leaves the DMA in "not ready" state (bit 9 = 0).

2. **BAR+0x030 = 0x10100** (mts_mac_init) -- frame config register.
   Drives TX frame size limits. Could gate the TX packet engine.

3. **BAR+0x07c = 0x17D7840** (mts_mac_init) -- 25 MHz clock divisor.
   If this drives the TX completion timer, its absence could prevent the
   TX engine from generating done-interrupts, but shouldn't prevent DMA
   fetch. Lower priority.

4. **BAR+0x008 |= 0x7597c00** (mts_mac_init) -- MAC feature/IRQ enable.
   Includes interrupt mask bits. Low priority for DMA fetch.

5. **BAR+0x010 RMW** (mts_mac_init) -- clear 0x91, set 0x81. MAC config
   bits including TX-enable, RX-enable. We don't write this register at all.

## Most likely root cause

**BAR+0x074 = 0x2277 (TX FIFO watermark)** is the most probable gate.
In sky2, the BMU watermark register (Q_WM) must be programmed before
PREF_UNIT_OP_ON or the BMU never transitions to operational state. On
Baikal, 0x074 is the analog. Without it, the TX DMA engine startup
sequence never completes, and bit 9 of 0x06c (TX DMA ready) stays 0.

The second candidate is **BAR+0x030 = 0x10100** (TX frame config),
which may need to be written before the TX engine accepts packets.

## Recommended test order

1. Write BAR+0x074 = 0x2277 before enabling TX engine
2. Write BAR+0x030 = 0x10100 before enabling TX engine
3. Check BAR+0x06c bit 9 after each -- does it auto-set?
4. If still 0, try write BAR+0x07c = 0x17D7840
5. If still 0, try BAR+0x010 RMW (clear 0x91, set 0x81)