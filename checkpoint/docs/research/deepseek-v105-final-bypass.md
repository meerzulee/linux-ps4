# deepseek-v105-final-bypass.md — 2026-05-13

## Honest answer: accept half-duplex. No bypass exists.

After 14 patches (v82→v104) and exhaustive Ghidra analysis of every Orbis
function touching BAR registers, **there is no software path that bypasses
the MAC link-up gate for TX.**

### (a) Management frame TX (FUN_c85f2250)

Uses the SAME descriptor engine at BAR+0x3c/0x44 as normal TX.  `softc+0x30e0`
is init'd to 0 (carrier polling enabled) — management frames are NEVER sent
in normal Orbis operation.  The disabled-polling path (0x30e0 != 0) sends them
via the descriptor ring, same TX engine, same gate.  Not a bypass.

### (b) No debug/test-mode register found

Audited all BAR offsets touched by Orbis (0x000–0x300 + 0xe80–0xf80 + parent
prelude 0x060–0x158).  No register accepts a "force TX engine on" write.
BAR+0x09c bit 6 is error-recovery only (destructive for active engines).
BAR+0x06c bit 9 is HW-status (read-only in practice).  BAR+0x204 controls IRQ
block, not TX DMA.  No undiscovered register in the 0x000–0x3ff range gates TX
independently of link-up.

### (c) mts_mac_init has no link-gate disable

All 20 BAR writes in `mts_mac_init` (`0xffffffffc85ecb60`) are documented and
replicated.  None control TX prefetch independently of the link-latch state
machine.

### What's been tried (and failed)

- All BAR+0x034/0x038 kick values (0x4 through 0xff through pulse)
- BAR+0x09c bit 6 toggle (packet engine reset — destructive to RX)
- BAR+0x200 master reset pulse
- BAR+0x138 = 2→1 state-machine trigger
- BAR+0x0a00 TX arbiter (register doesn't exist on Baikal)
- BAR+0xe88/0xe8c/0xe84 status ring (registers don't exist on Baikal)
- Status ring DMA with addresses (no-op, registers dead)
- Empty-rings probe strategy (v104) — latch still refused
- AN restart in ndo_open (v103) — PHY recovers, MAC ignores
- Every approach suggested by 4 agents across v93→v104

### Recommendation

Commit the driver as **RX-only half-duplex** with known limitations
documented.  RX works (v97).  Carrier tracking works (v94/95).  Link-up was
observed in v91.  The TX gate is a silicon-level interlock that requires the
MAC's one-shot link-latch to fire at the correct moment relative to engine
init — a timing constraint we can't satisfy with our current architecture.
The only untested path (full msk_init_hw replay) was proven destructive in
v90/v90b.

Future work: kexec-based snapshot of BAR state from a working Orbis boot to
identify the exact register values that differ.

--- deepseek-v41, 2026-05-13
