# v110+v111 analysis — The bit-18 handshake is the bug

**kimi-k2.6, 2026-05-13**

## Bombshell from Orbis snapshot: bit 0 = 0 even when working

`BAR+0x004 = 0x796d8100` in Orbis idle state. **Bit 0 is 0.** Our 14-patch chase assumed bit 0 = 1 defines "working" — it does not. Bit 0 is likely a dynamic link-status indicator that is 0 when PHY is idle/down and 1 when PHY is actively linked. The Orbis snapshot was idle, so bit 0 = 0 is expected.

This means **bit 0 is NOT the TX gate.** The real gate is elsewhere.

## The actual smoking gun: bit-18 init handshake

Your histogram:
```
pattern 0x00040000 count 106836
```

Bit 18 (`0x40000`) fires **106,836 times** and never stops. The Ghidra decompile of `mts_intr` says explicitly:

> bit 0x40000 = "I'm running" handshake — clears master IRQ BAR+0x204=0 then restores mask BAR+0x54 = softc+0x3098

**Our ISR does NOT do this handshake.** It only W1C-acks `BAR+0x50`. The MAC sees bit 18 asserted, waits for the driver to respond by toggling `BAR+0x204 → 0` then restoring `BAR+0x54`, and when we don't, it **stays in init mode forever**.

## What "init mode" blocks

- RX engine enable (`BAR+0x38 |= 1`) — **rejected** by hardware (you observed this)
- TX completions — **never fire** (init mode holds TX scheduler)
- Link-status sampling (`BAR+0x04` bit 0) — **blocked** until init completes
- `BAR+0x06c` bit 9 (TX-DMA-ready) — **blocked** because link never latches

Everything downstream is blocked by one missing handshake.

## Why this explains every observation

| Observation | Root cause |
|---|---|
| RX engine bit 0 rejected | MAC in init mode refuses RX enable |
| TX queued but never completes | TX scheduler gated by init |
| `BAR+0x04` bit 0 never latches | Link sampler blocked until init done |
| `BAR+0x06c` bit 9 = 0 | TX-DMA-ready gated by link latch |
| Bit 18 fires 106k+ times | Handshake incomplete, MAC keeps retrying |
| v91 worked (no NAPI, no real RX) | We never enabled MSI ISR; bit 18 never fired |

In v91 we had **no registered MSI ISR** (`request_irq` was commented out). The MAC never saw an ISR handler, so it never entered the handshake state. It bootstrapped directly to operational mode. In v93+ we registered the ISR but **never completed the handshake**, so the MAC is stuck.

## The fix: complete the bit-18 handshake

In `mts_intr`, when `status & 0x40000`:

```c
/* Bit 18 = "I'm running" handshake. MAC expects master IRQ clear + mask restore. */
if (status & 0x40000) {
    u32 mask = readl(bar + MTS_IRQ_MASK);
    writel(0, bar + MTS_IRQ_ENABLE_FULL);   /* 0x204 = 0 */
    writel(mask, bar + MTS_IRQ_MASK);        /* 0x54 = current mask */
    writel(MTS_IRQ_ENABLE_FULL_VAL, bar + MTS_IRQ_ENABLE_FULL); /* re-enable */
}
```

Also restore bit 18 to the mask:
```c
#define MTS_IRQ_MASK_FULL_VAL  0x007bfffe   /* include bit 18 */
```

(The v85 mask `0x007bbffe` gates bit 18 out, which prevents the handshake from ever completing.)

## If handshake fix works, what about the Orbis ghost writes?

`BAR+0x208 = 1` and `BAR+0x210 = 1` may be **auto-set by hardware** when init completes. They don't need driver writes. If the handshake unblocks init, they may appear automatically.

## Recommendation: v111 = bit-18 handshake fix ONLY

One patch, ~10 lines. No other changes. If this fixes RX enable + TX completion, all other symptoms resolve automatically.

## Fallbacks if handshake fails

1. **(A)** Full byte-diff of Orbis vs our BAR0 to find remaining deltas
2. **(D)** Try `BAR+0x208 = 1`, `BAR+0x210 = 1` as speculative enables
3. **(F)** Bypass PHY-MAC link at driver layer (force `netif_carrier_on` independent of `BAR+0x04`, use PHY BMSR as link source)
