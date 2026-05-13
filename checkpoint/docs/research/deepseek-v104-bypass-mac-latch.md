# deepseek-v104-bypass-mac-latch.md — 2026-05-13

## Brutal answer: no software bypass exists for the TX gate

BAR+0x06c bit 9 is a HW-status bit, not driver-writable.  It reflects the
MAC's internal "TX-DMA-ready" signal.  The signal goes high ONLY when
BAR+0x04 bit 0 latches to 1 (confirmed across v91–v103 boots).  Every TX
path in Orbis — management frame (FUN_c85f1890), normal data TX, error
recovery TX — uses the same descriptor engine gated by this signal.

**mts_intr error recovery (0x500000):** toggles BAR+0x09c bit 6, re-inits rings,
re-writes BAR+0x3c/0x44 (same paired-reg pattern as v97), kicks BAR+0x34 |= 1.
It does NOT write a special TX-ungate register.  It recovers from TX errors
while TX was ALREADY running — not a cold-start bypass.  If this path could
force-enable TX, our ndo_open ring init (identical writes) would already work.

**Management frame TX (FUN_c85f2250):** uses the SAME descriptor engine.  On
Orbis, this path only runs when `softc+0x30e0 != 0` (carrier polling
DISABLED) — a debug/special mode.  On production PS4 (carrier polling
enabled), management frames are NEVER sent.  This TX path was likely never
tested without link-up on MT7531 hardware.

## Why v91 latched and v97+ doesn't (one-shot theory)

v91: engines started in probe with zero-filled rings → PHY AN completes →
MAC sees first link transition → one-shot latch fires (BAR+0x04 bit 0 = 1).

v97+: engines started in probe → ndo_open zeros+refills rings → AN restart →
PHY re-negotiates → MAC's one-shot latch already consumed during the
engine-start window, refuses to re-evaluate.  The latch is edge-triggered on
the first internal link transition; once missed, no software can re-trigger it.

## Only viable path: Option A (move all init to ndo_open)

Match Orbis structure: `mts_mac_init` runs in `mts_ifup` (open path), NOT
probe.  This opens the latch window when the interface is brought up, with
rings prepared.  Restructure: probe allocates resources only; ndo_open runs
parent_prelude → mac_init → ring_init → engine_start → AN_restart → latch fires.

--- deepseek-v41, 2026-05-13
