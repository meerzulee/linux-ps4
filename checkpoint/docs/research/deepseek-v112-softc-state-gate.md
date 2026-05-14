# deepseek-v112-softc-state-gate.md — 2026-05-14

## Lead finding: ISR first-call path never runs in our driver — MAC stuck in init

**Root cause:** Orbis sets `softc+0x309c = 0` at the END of
`mts_init_rings_kick` (`0xffffffffc85ef1b0`).  The NEXT interrupt fires,
ISR sees `softc+0x309c == 0`, and runs the FIRST-CALL PATH:

```
softc+0x309c = 1;
BAR+0x204 = 0x10001388;   // enable full IRQ block
BAR+0x54  = 0x7bfffe;     // full IRQ mask
```

This happens AFTER engines are started (BAR+0x34/0x38 already running).
The MAC hardware sees: engines running → IRQ block enabled → transitions
to "init done" → bit-18 storm stops.

**Our driver** sets BAR+0x204 and BAR+0x54 EAGERLY in probe (mts_mac_init),
BEFORE engines are started.  The ISR never sees the first-call condition.
MAC sees: IRQ block enabled → engines not running yet → enters permanent
"waiting for init" mode → 5kHz bit-18 storm forever.

## Supporting evidence — softc state trace

| Field | Writer | Reader | Value in Orbis |
|-------|--------|--------|---------------|
| softc+0x309c | mts_init_rings_kick (=0), mts_intr first-call (=1) | mts_intr every entry | 0→1 on first post-ring-kick IRQ |
| softc+0x3098 | mts_intr saves 0x7bfffe before bit-18 handler? (inferred) | bit-18 handler (disables BAR+0x204, restores mask) | 0x7bfffe |
| softc+0x32b0 | mts_ifup (=0xa000000000000) | RX path? (not traced) | 0xa000000000000 |
| softc+0x314c | mts_attach via FUN_c8572e80 | mts_mac_init (gates multicast hash + BAR+0x1c8 \|= 0xc0000000) | 0 (gates hash out, Orbis snapshot confirms: BAR+0x1c8 top bits = 0) |

**Key feedback loop:** softc+0x309c = 0 → ISR first-call sets it to 1 +
programs BAR+0x204/0x54 → bit-18 handler may set it back to 0 (disabling
MAC) → next ISR re-runs first-call → handshake completes → bit-18 stops.

## Best-bet patch (~12 LOC, testable in 30s via hotswap)

In `ndo_open`, AFTER engine start + ring init, BEFORE napi_enable:

```c
/* Replicate Orbis mts_init_rings_kick final sequence:
 * reset first-call flag so the NEXT ISR re-programs BAR+0x204/0x54 */
mts->first_isr = true;  // new bool in struct mts, init to false in probe

/* Discard our eager BAR+0x204/0x54 values — let ISR set them */
writel(0, bar + MTS_IRQ_ENABLE_FULL);
writel(0, bar + MTS_IRQ_MASK);
(void)readl(bar + MTS_IRQ_MASK);
```

In ISR, at entry point (before histogram/NAPI):

```c
if (mts->first_isr) {
    mts->first_isr = false;
    writel(0x10001388, bar + MTS_IRQ_ENABLE_FULL);
    writel(0x007bfffe, bar + MTS_IRQ_MASK);
    (void)readl(bar + MTS_IRQ_MASK);
}
```

Then in the ISR bit-18 handler (when bit 18 is the ONLY unmasked bit):

```c
if ((status & ~mask) == 0x40000) {
    writel(0, bar + MTS_IRQ_ENABLE_FULL);
    writel(0x007bfffe, bar + MTS_IRQ_MASK);
    mts->first_isr = true;  // let next ISR re-run first-call
}
```

**Expected signal:** bit-18 storm drops to near-zero after the handshake
completes.  If TX wakes up within seconds, the init-done interlock is
the missing piece.

--- deepseek-v41, 2026-05-14
