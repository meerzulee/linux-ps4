# hermes — v93 Sony MTS descriptor format — 2026-05-13

Scope: re-decompiled Orbis 12.02 `mts_init_rings_kick` (`ffffffffc85ef1b0`), TX submit helper `FUN_ffffffffc85f1aa0`, `mts_tx_complete` (`ffffffffc85eeca0`), `mts_rx_process` (`ffffffffc85eea10`), `mts_rx_unwrap_one` (`ffffffffc85eed90`), and `mts_intr` (`ffffffffc85edcf0`). This is verified from the decompile, not inferred from sky2.

## Descriptor struct: 16 bytes, little-endian, 32-bit DMA address

Both TX and RX descriptors are 16 bytes:

```c
struct mts_desc {
    __le32 ctl_len;   /* +0x00: OWN/WRAP/flags/length */
    __le32 buf_lo;    /* +0x04: 32-bit buffer DMA address */
    __le32 aux0;      /* +0x08: TX sentinel/VLAN; RX VLAN tag */
    __le32 aux1;      /* +0x0c: TX TSO/checksum metadata; RX unused by driver */
};
```

I found no descriptor high-address field. The buffer address used by TX/RX is a single 32-bit write at descriptor `+0x04` (`FUN_c85f1aa0` lines 91-92, continuation lines 136-149; `mts_rx_unwrap_one` lines 106-109). Ring-base MMIO also writes only 32-bit values; Orbis writes the same loaded physical value to both paired registers (`BAR+0x44` and `BAR+0x3c` for TX ring, `BAR+0x48` and `BAR+0x40` for RX ring; `mts_init_rings_kick` lines 59-86). Treat this hardware as 32-bit DMA unless proven otherwise.

Common `ctl_len` bits:

- bit 31 (`0x80000000`): OWN/completion bit. Driver clears it to hand descriptor to HW. HW sets it when descriptor is done / CPU-owned.
- bit 30 (`0x40000000`): WRAP on descriptor index 255.

## Ring sizes and memory

`mts_attach` allocates 0x4000-byte DMA regions for TX and RX descriptor memory, but `mts_init_rings_kick` uses only 0x100 descriptors * 0x10 bytes = 0x1000 bytes per ring. Hard limit is 256 descriptors; all producer/consumer indices wrap after `0xff`.

Additional data-buffer arenas:

- TX copy arena: 0xa0000 bytes. `FUN_c85f1aa0` copies mbuf chains into this arena and uses a circular offset at `softc+0x32b0`, completion reclaim at `softc+0x32b4`.
- RX copy arena: 0x60000 bytes = 256 * 0x600. Each RX descriptor points to `rx_dma_base + idx * 0x600`.

## `mts_init_rings_kick`: ring initialization

TX ring init (`mts_init_rings_kick` lines 20-35):

- `tx_prod = 0`, `tx_free = 0x100`.
- Zeroes 0x1000 bytes of TX descriptor memory.
- For each of 256 descriptors:
  - descriptor pointer table entry = current desc pointer.
  - `ctl_len = 0x80000000` (CPU-owned/free, not handed to HW).
  - `aux0 |= 0xffff0000` sentinel marking unused/free for completion logic.
  - associated mbuf pointer = NULL.

RX ring init (`mts_init_rings_kick` lines 37-55):

- `rx_cons = 0`.
- Zeroes RX descriptor memory.
- For each of 256 descriptors:
  - `ctl_len = 0x80000600` initially.
  - `buf_lo = rx_dma_base + idx * 0x600`.
  - if idx 255, set WRAP bit (`ctl_len |= 0x40000000`).
  - finally clears OWN bit (`ctl_len &= 0x7fffffff`) to hand RX buffer to HW.

So yes: it pre-fills OWN bits. TX descriptors stay OWN=1/free. RX descriptors are built with OWN=1, then immediately changed to OWN=0/HW-owned.

Kick/register programming:

- TX ring base: `BAR+0x44 = tx_ring_dma`, `BAR+0x3c = tx_ring_dma`.
- RX ring base: `BAR+0x48 = rx_ring_dma`, `BAR+0x40 = rx_ring_dma`.
- `BAR+0x34 |= 1`, `BAR+0x38 |= 1`, then `BAR+0x54 = irq_mask`.
- Despite some old Linux labels, Orbis TX submit later kicks `BAR+0x34 |= 4`; RX refill interrupt path kicks `BAR+0x38 |= 4`. So `0x34` behaves as TX kick and `0x38` as RX kick in the packet path.

## TX descriptor format / submit path

TX submit is `FUN_ffffffffc85f1aa0`; wrapper `FUN_ffffffffc85f1890` allocates an mbuf, copies a small management frame, calls `FUN_c85f1aa0`, then kicks `BAR+0x34 |= 4` and waits for response sequence.

TX `ctl_len` fields from `FUN_c85f1aa0`:

- bit 31 OWN: initialized/set while software fills descriptor; driver clears bit 31 on the first descriptor only after the entire chain is prepared (`line 166`).
- bit 30 WRAP: set when descriptor index is `0xff` (`lines 123-125`, continuations `150-153`).
- bit 29 `0x20000000`: set on the first descriptor of a frame (`line 112`). This is very likely SOF.
- bit 28 `0x10000000`: set on the last descriptor of a frame (`lines 162-163`). This is very likely EOF.
- bit 26 `0x04000000`: set when mbuf has VLAN tag (`lines 105-110`); `aux0 = 0x81000000 | (vlan & 0xfff)`.
- bit 25 `0x02000000`: set if mbuf flag word has bit `0x1` (`lines 93-96`).
- bit 24 `0x01000000`: set if mbuf flags have `0x2004` (`lines 98-100`).
- bit 23 `0x00800000`: set if mbuf flags have `0x4002` (`lines 102-104`).
- bit 18 (`byte +2 |= 0x04`): set for the TSO/checksum path when `(mbuf_flags & 0x20) != 0` (`lines 84-88`, `114-122`, continuation `141-149`).
- low length field: TX writes the low 16 bits from split segment lengths. First descriptor ORs `(uint)local_430[0]` into `ctl_len` (`line 112`); continuation descriptors write `(uint)*puVar10` (`line 136`). Segments are split at maximum `0xff80`, so do not limit TX length to RX’s 11-bit mask.

TX `buf_lo`:

- First descriptor `buf_lo = tx_dma_base + tx_offset` (`line 92`).
- Continuation descriptors get subsequent split addresses (`lines 136-138`).

TX `aux0`:

- Free/sentinel state has upper 16 bits set: `aux0 |= 0xffff0000` in init and after completion.
- Normal non-VLAN TX sets `aux0 = 0`.
- VLAN TX sets `aux0 = 0x81000000 | (vlan & 0xfff)` and `ctl_len bit26`.

TX `aux1`:

- Normal TX: `0`.
- TSO/checksum path: `aux1 = (packet_len & 0x1fffff) | (param_2[9] << 21)` (`lines 84-88`, `117-122`). Exact semantic names for the high field are not proven by this pass.

TX completion (`mts_tx_complete`):

- It starts at `tx_cons = softc+0x305c`.
- It only processes descriptors with `ctl_len` bit31 set (`*piVar5 < 0`, lines 17-20 and loop condition line 44).
- It refuses to process a free/unused descriptor if `aux0 >= 0xffff0000` (`line 22`). This is the sentinel written by init/completion.
- For a submitted descriptor, it frees the saved mbuf pointer, updates TX arena reclaim offset from `buf_lo - tx_dma_base`, sets `aux0 |= 0xffff0000`, advances index, increments free count.

Thus HW completion signal for TX is: OWN/bit31 set back to 1 on a descriptor whose `aux0` upper sentinel is not `0xffff`.

## RX descriptor format / completion path

RX descriptors are initialized/refilled by `mts_init_rings_kick` and `mts_rx_unwrap_one`:

- `ctl_len = 0x80000600`, then WRAP if idx 255, then clear OWN to hand to HW.
- `buf_lo = rx_dma_base + idx * 0x600`.
- `aux0`/`aux1` are zeroed by initial ring memset; refill does not explicitly clear them.

RX completion detection (`mts_rx_process`):

- Current RX index is `softc+0x3064`.
- It processes while `ctl_len >= 0x80000001` (`line 26`), i.e. OWN bit set and nonzero status/length. If descriptor is still HW-owned (`OWN=0`) or exactly not complete, it stops.
- It processes at most 256 packets in one pass.

RX `ctl_len` fields consumed by `mts_rx_unwrap_one`:

- bits 0..10: received packet length (`ctl_len & 0x7ff`, line 35). The mbuf length and copied length are set to this value (`lines 46-47`, copy lines 80-82).
- bit 16 (`0x00010000`), bit 17 (`0x00020000`), bits 18..19, and bit 26 are interpreted only for checksum status mapping into mbuf flags (`lines 48-75`). Exact checksum meaning names are not proven here; preserve bit tests if implementing offload later.
- bit 20 (`byte +2 & 0x10`): VLAN-present indicator. If set, driver copies VLAN tag from `aux0 & 0xfff` and sets mbuf VLAN flag (`lines 76-79`).
- bit 30 WRAP is preserved/refilled for index 255.
- bit 31 OWN/completed as above.

After unwrap, Orbis refills the same descriptor (`lines 104-115`):

```c
ctl_len = 0x80000600;
buf_lo  = rx_dma_base + idx * 0x600;
if (idx == 0xff) ctl_len |= 0x40000000;
ctl_len &= 0x7fffffff;   // hand back to HW
```

## Interrupt bits from `mts_intr`

`mts_intr` reads `BAR+0x50`, writes the same value back to ACK, then dispatches:

- `0x00000004`: link change. Calls `mts_link_change`, then wakes `gbe:phy_ctrl` with event `0x100` if BAR+0x04 bit0 is up, else event `1`.
- `0x00000080`: TX completion. Calls `mts_tx_complete`; if TX free count < 256, kicks `BAR+0x34 |= 4`, else clears a soft ifnet flag.
- `0x00000040`: RX available. Calls `mts_rx_process`.
- `0x00000022`: RX-related condition. Calls `mts_rx_process`, then kicks `BAR+0x38 |= 4`.
- `0x001000`: VLAN/control event when secondary mode enabled; masks bit `0x1000` in BAR+0x54 and wakes `gbe:ctrl` event bit 2.
- `0x00040000`: special first-interrupt/IRQ-block transition path; disables BAR+0x204 and restores BAR+0x54 under a soft state guard.
- Error group `0x007be600` includes packet-engine recovery and fatal printk paths:
  - `0x00500000`: packet-engine recovery: toggles BAR+0x09c bit6 clear/set, resets TX descriptors, reloads TX ring base, kicks `BAR+0x34 |= 1`.
  - `0x00200000`: `LSO_FIFO_EMPTY` fatal printk.
  - `0x00080000`: `LSO_PRO_ERR` fatal printk.
  - `0x00020000`: `RX_AXI_ERR` fatal printk.
  - bit15: `IP_CKS`; bit14: `TCP_CKS`; bit13: `UDP_CKS`; bit10: `RX_PCODE`.

## Implementation cautions

- Do not use sky2 descriptors. MTS descriptors are 16-byte, 32-bit-address descriptors with inverted OWN handoff semantics (driver clears bit31 to give to HW).
- Do not assume TX length is 11 bits. RX masks length with `0x7ff`; TX writes 16-bit segment lengths and splits at `0xff80`.
- Preserve WRAP at descriptor 255 only.
- For a minimal Linux netdev, initially disable/checksum-offload/VLAN/TSO handling and write normal TX descriptors: `ctl_len = SOF|EOF|len|WRAP?`, `buf_lo = dma32`, `aux0=0`, `aux1=0`, then clear bit31 last and kick `BAR+0x34 |= 4`.
- For RX, initialize/refill exactly as Orbis: `0x00000600` (plus WRAP on last) with a 0x600-byte DMA buffer, then on completion use `len = ctl_len & 0x7ff`, copy/map packet, refill, clear OWN last.
