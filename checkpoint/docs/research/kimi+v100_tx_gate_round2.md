# v100 — TX gate round 2: 0x080 ruled out, 0x06c is the prime suspect

**kimi-k2.6, 2026-05-13**

## Q1 — TX_FIFO ready vs TX clock domain

**TX clock domain is now more likely.** RX proves the main MAC clock is alive, but many dual-clause MACs run TX and RX FIFOs on separate gated clocks derived from the same PLL. If the TX clock gate never opened, the scheduler sees valid descriptors but cannot advance its state machine — exactly the "stationary BAR+0x03c" signature.

## Q2 — Register audit

| Offset | Value | Pattern read |
|---|---|---|
| `0x05c` | `0x00101000` | Threshold-like (bits 12+20); could be FIFO watermark |
| `0x060` | `0x00032100` | Matches prelude ✅ |
| `0x064` | `0x00000006` | Matches prelude ✅ |
| `0x06c` | `0x00000100` | **CRITICAL MISMATCH** — prelude wrote `0x300` (bits 8+9); only bit 8 reads back |
| `0x070` | `0x00010003` | Untouched; bits 0+1+16 — possible pause/flow-control threshold |
| `0x0b0` | `0x001f03ff` | Mask-like — likely FIFO full/empty watermark |
| `0x0b4` | `0x001fffff` | Mask-like — likely FIFO size or burst limit |
| `0x1c8` | `0x00a00000` | Ring-control/mcast; bits 21+23 set, unusual for a ring register |

`0x06c` is the smoking gun: **bit 9 (0x200) is missing**. If bit 9 is a TX clock/FIFO enable and bit 8 is RX, the readback perfectly explains RX-alive/TX-dead.

## Q3 — 0x064 toggle hypothesis

Unlikely. The register already reads `0x6` (bits 1+2 set). If these bits released the FIFO from reset, they are already released. A toggle would only matter if the POR default was not `0x6`, but the current value suggests the block is already out of reset.

## Recommended next test

1. **Toggle 0x06c**: Write `0x100`, wait 1 ms, write `0x300`, read back. If bit 9 still reads 0, the write is being rejected or shadowed by a prerequisite.
2. **Check 0x0b0/0x0b4**: If these are TX FIFO thresholds, try writing `0x001f03ff` / `0x001fffff` explicitly (they may be POR defaults that need a write-one-to-accept).
3. **Check 0x070**: Try clearing bits 0-1 or setting bit 16 — this could be a TX-side pause/watermark gate.
