# hermes / gpt-5.5 — 2026-05-13

Prediction: the Orbis child MTS BAR0 dump will NOT reveal a giant missing MAC-init block. Ignoring volatile counters, ring DMA addresses, producer/consumer indices, and IRQ-pending bits, I expect the stable control/status delta to be tiny: link-latch status, TX-ready status, and probably the DA/filter accept-all residue at `0x1c8` / `0x1c4`.

## Q1/Q2 — predicted offsets and values

Hard prediction, ordered by confidence:

| offset | our v97 broken-TX value | predicted Orbis value | why |
|---:|---:|---:|---|
| `0x004` | `0x00000b18` | `0x00000b19` | `bit0` is the MAC link latch. Orbis has working TX/link, ours has the same speed/duplex-ish high bits but no latch. |
| `0x06c` | `0x00000100` | `0x00000300` | `bit9` is HW TX-ready/status and follows `0x004[0]`. Orbis TX flows, so bit9 should be set; bit8 remains set. |
| `0x1c8` | `0x00a00000` | `0xc0a00000` | My best non-status bet: Orbis takes/retains the DA/filter accept-all bits 30+31, while our path only has the `0x00a00000` length/field residue. |
| `0x1c4` | likely `0x00000000` or stale | `0x00000003` | If Orbis ran the DA/filter block, this is the “filter load done” strobe residue. This is the single most likely new offset besides `0x1c8`. |

Second-tier predicted differences I would not treat as root cause without time-correlating:

| offset | predicted Orbis tendency | why |
|---:|---|---|
| `0x034` | may differ | TX doorbell/control runtime state; Orbis has transmitted frames, ours may only pulsed/parked. |
| `0x038` | may differ | engine/ring run-state bits are pulse/status-like; likely runtime, not missing init. |
| `0x050` | may differ | IRQ status/W1C pending bits; Orbis traffic can leave different RX/TX/link pending bits. |
| `0x03c/0x044` | different physical addresses | TX ring base points at Orbis kernel memory, not Linux DMA memory. Not semantically useful. |
| `0x040/0x048` | different physical addresses | RX ring base same issue. |
| `0x070..0x0ff` and MIB-ish ranges | may differ | packet/error counters from real Test Connection traffic. Ignore for latch diagnosis. |

Negative predictions:

- `0x030` will match `0x00010100`. The prompt says our compare state already has it, and Orbis writes the same value in `mts_mac_init`.
- `0x200` will match `0x00000000`. v106 falsified it as the release edge; Orbis should not need a persistent nonzero value there.
- `0x054` will probably match or be operationally equivalent to `0x007bfffe`. A mask delta alone is not my predicted TX gate.
- I do not expect child BAR `0xf04`/`0xf10` to explain the diff; the parent-BAR theory was about `00:14.0`, while this dump is KVA for child BAR physical `0xc2000000`.

## Q3 — if the diff is exactly only `0x004[0]` and `0x06c[9]`

That proves the missing TX enable is not a BAR-visible child register configuration. It would mean our BAR0 programming has converged to Orbis at the stable register level, and the failure is in hidden state/timing:

1. `0x004[0]` is a hardware latch, not a software-owned bit.
2. `0x06c[9]` is downstream status derived from that latch, not a writable TX enable.
3. The decisive difference is the event edge Orbis catches: parent/child reset sequencing, GMII/RGMII link transition timing, or PHY-to-MAC signal observation order.
4. No final child BAR poke should be expected to “set TX ready”; at that point, ship RX-only unless we replicate Orbis parent+child init ordering structurally.

In other words: exact two-bit status-only diff exonerates `mts_mac_init` final values and condemns the invisible sequencer/latch window.

## Q4 — if the diff includes a register we never wrote

Most likely offset: `BAR+0x1c4`, predicted value `0x00000003`.

Reason: the clearest Orbis-only child-BAR residue from the RE notes is the conditional DA/filter loader: it writes entries through `0x1bc/0x1c0`, polls `0x1d0`, then leaves `0x1c4 = 3` and ORs `0xc0000000` into `0x1c8`. We have focused on `0x1c8`, but a raw snapshot may show the companion `0x1c4` done-strobe as the never-written smoking gun.

If I must name one register, not a range: `0x1c4 = 0x00000003`.

Recommended interpretation rule: if Orbis has `0x1c8 = 0xc0a00000` and/or `0x1c4 = 3`, test those once. If Orbis lacks them and the only durable delta is `0x004/0x06c` status, stop register roulette and ship RX-only.
