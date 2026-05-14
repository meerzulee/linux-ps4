# v108 — Orbis BAR0 snapshot prediction

**kimi-k2.6, 2026-05-13**

## Predicted diffs vs v97 broken-TX state

| Offset | Our v97 value | Predicted Orbis value | Rationale |
|---|---|---|---|
| **0x004** | `0x00000b18` | **`0x00000b19`** | Bit 0 = link UP. Speed/duplex/aux same. |
| **0x06c** | `0x00000100` | **`0x00000300`** | Bit 9 follows bit 0 — TX DMA ready gate open when link latched. |
| **0x1c8** | `0x00a00000` | **`0x00a00040`** | Orbis `mts_init_rings_kick` sets bit 6 (`0x40`) after ring init. We never wrote this offset. |
| **0x208** | `0x00000000` (or unset) | **`0x00000001`** | Observed as `0x1` on running PS4 (v89). We never wrote it. |
| **0x210** | `0x00000000` (or unset) | **`0x00000001`** | Same observation as 0x208. |
| **0x118** | `0x000000a7` | **`> 0xa7`** | RX symbol counter — higher because Orbis has real traffic. |
| **0x128** | `0x00000080` | **`> 0x80`** | Active counter, grows with TX/RX activity. |
| **0x12c** | `0x00000096` | **`> 0x96`** | Active counter, grows with TX/RX activity. |

## Q3: If diff is EXACTLY 0x004 and 0x06c only

It proves they are **pure read-only status bits** downstream of the actual TX enable. The MAC's internal link-state machine sets both together, and neither is writable by software. This means there is a **third, upstream register** we have not found that gates the link-state machine itself. The hunt would shift to identifying which BAR offset controls the "PHY MII sample enable" or "PCS sync qualify" signal.

## Q4: Most likely "never written" diff offset

**0x208** or **0x210**.

These showed `0x1` on a running PS4 (v89 observation) but our driver has **zero writes** to either offset. If they differ from zero in the Orbis snapshot, they are strong candidates for the missing TX gate — possibly a "descriptor prefetch enable" or "TX scheduler arm" bit that the Orbis bootloader or `msk_init_hw` sets, and our `mts_mac_init` skips.

**Skin in the game**: If 0x208/0x210 are `0` in Orbis, my core hypothesis collapses and the actual gate is in `BAR+0x080` mode bits we misidentified.
