# deepseek-v108-snapshot-prediction.md — 2026-05-14

## Q1 + Q2 — Predicted diff: Orbis working state vs our v97 broken-TX state

### High confidence (expect to differ)

| Offset | Our v97 | Orbis predicted | Why |
|--------|---------|----------------|-----|
| 0x004 | 0x00000b18 | **0x00000b19** | Bit 0 = link UP. All other bits (speed=1000M, duplex=full) identical. |
| 0x06c | 0x00000100 | **0x00000300** | Bit 9 = TX-DMA-ready. This IS the TX gate. Bit 8 already set both sides. |
| 0x054 | 0x007bbffe | **0x007bfffe** | We gate bit 18 (0x40000). Orbis leaves it enabled — ISR handles it. |
| 0x050 | 0x00040000 | **0x00000000** | Orbis ISR keeps status clean. Our bit 18 is stuck-pending. |
| 0x204 | 0x10001388 | **0x10001388** OR **0x00000000** | If Orbis bit-18 handler fired: 0. If MAC healthy: same as ours. |

### Medium confidence (likely differ — traffic counters)

| Offset | Our v97 | Orbis predicted | Why |
|--------|---------|----------------|-----|
| 0x118 | ~0xa7 | **higher** (>200) | RX packet counter. Orbis sent real TX traffic through the switch. |
| 0x100 | 0x0003 | **higher** | Possible TX-packet counter. |
| 0x208 | 0x0001 | **0x0001** or **0x0003** | Auto-set engine-ready bits. Orbis might have both TX+RX ready. |
| 0x210 | 0x0001 | **0x0001** | RX engine ready. Probably same. |

### Low confidence (might be same — init-derived values)

| Offset | Both likely | Notes |
|--------|-------------|-------|
| 0x030 | 0x10100 | MAC_MODE — same init value |
| 0x08 | 0x0f597c00 | MAC_CTRL1 — same OR mask |
| 0x0c | bit7=0 | MAC_CTRL2 — same clear-bit-7 |
| 0x200 | 0 | Master reset clear — same |
| 0x07c | 25000000 | MAC clock — same |
| 0x03c/0x44 | diff DMA addrs | Different allocations, same pattern |

### Most likely "never written by us" register that differs

**BAR+0x09c**: Our value is 0x6f (from init). Orbis ISR toggles bit 6 during TX
operation in the error-recovery path. If Orbis ISR has run even once, the value
might be 0x6f or might have settled differently.  **Predicted: same (0x6f)**
unless TX error recovery path ran.

**BAR+0x080**: Our value 0x000002bb. This is GMAC PCS status. Orbis might
differ if the PCS is in a different sync state with active TX. It's a status
register, not control — but could be a *symptom* of the TX gap.

**BAR+0x138**: Orbis msk_init_hw writes 2→1 here, which we tried and failed.
In Orbis, the final value should be 1 (after the 2→1 transition). Our value
is whatever was there from kexec (we didn't write it before v100). **If 0x138
is a readback register, Orbis likely has 0x00000001. If it's write-only latch,
readback is garbage.**

## Q3 — If diff is ONLY status bits (0x04 bit 0 + 0x06c bit 9)

That proves the MAC silicon is in the SAME software-configured state as Orbis,
and the link-latch + TX-gate are purely HW-driven status that our driver CANNOT
influence without running msk_init_hw FIRST (in the correct order).  It also
proves our decompile + replication of all writable BAR registers is 100% correct.

## Q4 — If diff includes a register we've never written

Most likely candidate: **BAR+0x09c** if Orbis ISR has toggled bit 6 during TX
operation.  Next: **BAR+0x080** (PCS status reflecting operational link).

Wild card: a register in the **0x0e0–0x0ff** range (between PKT engine and
multicast hash) that msk_init_hw writes but we don't.  msk_init_hw writes
at 0x138, 0xe08, 0xe18, 0xf00–0xf80.  If any of these offsets map to
DESTROYED-region registers in our driver (0x0e0–0x0ff), we'd see a value
Orbis set that we never touched.

--- deepseek-v41, 2026-05-14
