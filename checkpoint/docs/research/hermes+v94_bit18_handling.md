# Hermes (gpt-5.5) — v94 bit-18 interrupt handling audit — 2026-05-13

Concrete finding: Orbis does not treat `0x00040000` as a normal packet/link IRQ.  It is a transition/handshake interrupt for the Baikal MTS interrupt block itself.  In `mts_intr` (`FUN_ffffffffc85edcf0`) Orbis first enables the block lazily, then if the only effective pending cause is bit 18, it disables the master IRQ block again and restores a saved per-source mask.  That is why our permanent eager enable (`BAR+0x204 = 0x10001388`) can turn bit 18 into a level flood.

Precise path in Orbis:

- `mts_intr` entry takes `softc` and locks `softc+0x30b0` (`if_mts.c:0x10c9` in the decompile, `/tmp/v93-ghidra/mts_intr.c:22-24`).
- If `softc+0x309c == 0`, it sets `softc+0x309c = 1`, writes `BAR+0x204 = 0x10001388`, then writes `BAR+0x54 = 0x007bfffe` (`mts_intr.c:25-40`; asm `ffffffffc85edd50..c85eddad`).  This is the lazy “IRQ block now armed” transition.
- The ISR then reads `BAR+0x50` into `uVar4/status` and computes `effective = status & ~*(u32 *)(softc+0x3098)` using BMI `ANDN` in asm (`mts_intr.c:42-50`; asm `ffffffffc85ede40..c85ede50`).  Important: `softc+0x3098` is Orbis’s saved software mask/restoration value, not necessarily the literal live `0x7bfffe` written during the transition.  `mts_init_rings_kick` later writes `softc+0x3098` back to `BAR+0x54` and clears `softc+0x309c` (`/tmp/v93-ghidra/mts_init_rings_kick.c:115-122`; asm `ffffffffc85ef3da..c85ef3fc`).
- After W1C-acking `BAR+0x50`, Orbis checks the special case: `if ((status & ~softc->saved_mask) == 0x40000 && softc+0x309c == 1)` (`mts_intr.c:178`; asm `ffffffffc85ee0eb..c85ee106`).  If true, it sets `softc+0x309c = 0`, writes `BAR+0x204 = 0`, then writes `BAR+0x54 = softc+0x3098` (`mts_intr.c:178-193`; asm `ffffffffc85ee108..c85ee15?`).

Interpretation: bit 18 is not self-clearing via the normal `BAR+0x50 = status` W1C alone.  It is quieted by backing the block out of the temporary full-enable state: master disable at `0x204`, and restore the pre-transition source mask at `0x54`.  Orbis only enters that state when `softc+0x309c` says the driver itself just performed the lazy enable.  Once the handshake is consumed, `0x309c` is reset.  Later `mts_init_rings_kick` can deliberately re-arm the transition when ring state changes.

Why Orbis sees it once but Linux sees it constantly: our driver writes `0x204=0x10001388` and `0x54=0x7bbffe/0x7bfffe` eagerly during `mts_mac_init` and keeps the master block enabled forever.  We also do not model `softc+0x3098/0x309c` as a two-state handshake.  If bit 18 is a level “full IRQ block transition/idle” condition, W1C ack immediately reasserts.  v84a’s 5670 Hz `irq_status=0x00040000` is exactly that failure mode.

Can we re-enable bit 18 cleanly?  Only if we implement the Orbis state machine, not merely an ack.  Minimal safe experiment would add `irq_armed_transition` and `saved_mask` fields: before starting rings, write `BAR+0x54 = saved_mask`, set `irq_armed_transition = 0`; on first interrupt with flag 0, set flag 1 and write `0x204=0x10001388`, `0x54=0x7bfffe`; if effective status is exactly bit18 and flag 1, write `0x204=0`, restore `0x54=saved_mask`, clear flag, and return.  But this may suppress normal RX/TX IRQs unless we also understand when Orbis re-enables the master block.

Conclusion: permanently gating bit 18 (`0x007bbffe`) is safe for a Linux netdev unless future hardware evidence shows missing state transitions.  Orbis’s normal packet paths are bit 2 link, bit 6/0x22 RX, and bit 31 TX complete; bit 18 is a control handshake, not required data-plane completion.

Recommended next experiment on hardware: keep bit 18 gated for v94/v95; add a read-only telemetry counter for raw `BAR+0x50 & 0x40000` in the 5s debug dump to confirm the source remains asserted without allowing it to interrupt.
