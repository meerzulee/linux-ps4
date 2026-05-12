# Orbis ethernet driver REVERSE ENGINEERED — `if_mts` is the answer (2026-05-12)

**TL;DR:** Baikal GBE on PS4 is driven by a Sony-custom FreeBSD driver internally
named `if_mts.c` (`W:\Build\J02688428\sys\freebsd\sys\dev\mts\if_mts.c`). It is
**NOT** Synopsys DWMAC1000 (rmuxnet's guess) and **NOT** Marvell Yukon-2 (sky2's
register layout). The MAC is a custom AXI-bus IP block with a Realtek-family
PHY accessed via a custom "SMI" MDIO controller at **BAR+0x00** of the GBE PCI
device. Sky2's v69 MDIO scan failed because it probed Yukon GPHY_REG offsets,
not the actual SMI register.

This document captures everything needed to write `drivers/net/ethernet/sony/ps4_mts.c`
from scratch. No further Orbis RE round-trips should be needed for a first-pass
bring-up.

## Source dump

All findings are from Ghidra MCP on
`checkpoint/docs/research/orbis-kernel/orbis-12.02.elf` (PS4 firmware 12.02
kernel). Project `orbis-ps4-dump`.

Key Orbis driver functions (stripped binary — addresses, not symbols):

| Function | Address | What it does |
|---|---|---|
| `mts_probe` | `0xffffffffc85ebf10` | PCI probe — matches vendor `0x104d` device `0x90d8`, returns `"Baikal GBE controller"` |
| `mts_attach` | `0xffffffffc85ec030` | Resource allocation, mutex init, DMA tag/ring setup, MAC init dispatch |
| `mts_mac_init` | `0xffffffffc85ecb60` | The big register-level MAC + PHY bring-up sequence |
| `mts_intr` | `0xffffffffc85edcf0` | ISR — runs in a loop until status reg reads 0 |
| `mts_smi_cl22_read` | `0xffffffffc85ee800` | MDIO Clause 22 read |
| `mts_smi_cl22_write` | `0xffffffffc85ee910` | MDIO Clause 22 write |
| `mts_smi_cl45_read` | `0xffffffffc85ee640` | MDIO Clause 45 read (split address + data phase) |
| `mts_smi_cl45_write` | `0xffffffffc85ee490` | MDIO Clause 45 write (split address + data phase) |
| `mts_link_change` | `0xffffffffc85eeb90` | Decode link/speed/duplex from BAR+4 status |
| `mts_rx_process` | `0xffffffffc85eea10` | RX-ring drain (up to 256 packets per call) |
| `mts_tx_complete` | `0xffffffffc85eeca0` | TX completion handler |

The Orbis "MTS" driver name is presumably a Sony internal codename. The IP block
itself has all the appearance of a Marvell-derived custom MAC with Sony glue —
LSO offload, IP/TCP/UDP checksum offload, AXI bus, multicast hash filter,
secondary MAC address — but the register layout does not match any open Marvell
driver in mainline (sky2, msk, mvneta, mvpp2, octeontx2). Treat as a from-scratch
target.

## Critical hardware facts

- **PCI ID:** vendor `0x104d` (Sony), device `0x90d8` (Baikal GBE).
- **Slot:** `0000:00:14.1` (function 1 of Baikal's BPCIE bridge — same slot as Aeolia/Belize GBE, different silicon).
- **BAR0:** memory-mapped 32-bit registers. Driver code uses indirect resource
  accessors with both MMIO and PIO fallback paths (FreeBSD `bus_space`-style).
  In practice all accesses go through MMIO on PS4. **Linux equivalent: `readl`/`writel`.**
- **PHY:** Realtek RTL8211-family. Identified by the magic-poke sequence
  `0x52b5 → reg 0x1f` (Realtek's extended-page select; documented in mainline
  `drivers/net/phy/realtek.c`). Reached via the SMI controller at BAR+0x00.
- **IRQ:** standard PCI MSI through the BPCIE composer. The existing PS4 bpcie
  infrastructure already routes this correctly — sky2 v68 confirmed MSI delivery
  works at this PCI function.
- **DMA:** descriptor rings at separate dma_tags, 16 KB each. Driver pre-allocates
  256 software-tracking slots × 24 bytes for both TX and RX directions.

## Register map (BAR0, by offset)

The MTS driver decompilation gives us this register cluster. Names below are
inferred from neighbouring code:

| Offset | Name (inferred) | Description |
|---|---|---|
| `0x000` | `SMI_CMD` | MDIO command/status. **See SMI section below.** |
| `0x004` | `LINK_STATUS` | bit 0 = link up; bits 2-3 = speed (00=10M, 01=100M, 10=1000M); bit 4 = full duplex; bit 6 = flow ctrl; bit 8 = aux state |
| `0x008` | `MAC_CTRL` | OR with `0x07597C00` during init |
| `0x00c` | `MAC_CTRL2` | clear bit 7 during init |
| `0x010` | `MAC_CTRL3` | mask `0xFFFFFF6E`, OR `0x81` |
| `0x014` | `MAC_ADDR0_HI` | bytes [0..3] of MAC, byte-swapped |
| `0x018` | `MAC_ADDR0_LO` | bytes [4..5] of MAC in upper 16 bits, byte-swapped |
| `0x030` | `MAC_MODE` | written `0x10100` |
| `0x034` | `IRQ_KICK` / `RX_RESTART` | bit 0 = RX restart; bit 2 = (RX-after-restart re-arm?) |
| `0x038` | `TX_RESTART` | bit 2 set on TX bus error recovery |
| `0x03c` | `TX_DESC_BASE_LO` | TX descriptor ring physical address (low 32) |
| `0x044` | `TX_DESC_BASE_HI` | TX descriptor ring physical address (high 32) — same value written in init, suggests 32-bit addresses or duplicated/aliased register |
| `0x050` | `IRQ_STATUS` | read/write-1-to-clear |
| `0x054` | `IRQ_MASK` | bit n set = enable irq n |
| `0x074` | `MAC_PAUSE` | written `0x2277` |
| `0x078` | `RX_GATE` | bit 0 clear at end of init (enable RX?) |
| `0x07c` | `MAC_CLK` | written `25000000` (25 MHz reference) |
| `0x09c` | `PKT_ENGINE_CTRL` | bit 6 toggled during error-recovery on irq bits `0x500000` |
| `0x0ac` | `?` | written 9 in init |
| `0x140` | `MAC_ADDR1_HI` | secondary MAC (bit 31 = enable) |
| `0x144` | `MAC_ADDR1_LO` | secondary MAC |
| `0x1bc` | `MCAST_HASH_DATA` | multicast hash slot data |
| `0x1c0` | `MCAST_HASH_IDX` | multicast hash slot index (bit 7 = commit) |
| `0x1c4` | `MCAST_HASH_CTRL` | 1 = start cycle, 3 = end with broadcast accept, OR'd `0xC0000000` for promisc-like mode |
| `0x1c8` | `MCAST_HASH_MASK` | OR'd `(uVar6 * 0x100) | uVar6` where `uVar6 = (loop_count) + 0x20` |
| `0x1d0` | `MCAST_HASH_DONE` | bit 0 = transaction done |
| `0x1d4` | `?` | written 1 in init |
| `0x200` | `?` | written 0 at very start of init (master reset clear?) |
| `0x204` | `IRQ_ENABLE_FULL` | `0x10001388` enables, `0` disables — set in ISR's first branch |

## SMI MDIO controller (BAR+0x00)

The SMI register is a **single 32-bit command/result word**. The format is:

### Clause 22 read
```c
writel(0x8000, BAR+0);                     // arm
writel(0x4000 | (reg & 0x1f) << 8, BAR+0); // read cmd
// poll until bit 15 of low 16 bits is set
do {
    val = readl(BAR+0);
    if ((short)val < 0) break;             // bit 15 set = done
    udelay(1);
} while (--timeout);
*out = val >> 16;                          // upper 16 bits = read data
```

### Clause 22 write
```c
writel(0x8000, BAR+0);
writel(0x2000 | (reg & 0x1f) << 8 | (val << 16), BAR+0);
// poll bit 15 same way
```

### Clause 45 (MMD) — two phases
```c
// Phase 1: set address (push reg-high into MMD's internal addr reg)
writel(0x8000, BAR+0);
writel(0x20 | (devad & 0x1f) << 8 | (regaddr_high & 0xffff) << 16, BAR+0);
// poll bit 15

// Phase 2A: read data
writel(0x8000, BAR+0);
writel(0xe0 | (devad & 0x1f) << 8, BAR+0);
// poll bit 15, data = val >> 16

// Phase 2B: write data
writel(0x8000, BAR+0);
writel(0x60 | (devad & 0x1f) << 8 | (val << 16), BAR+0);
// poll bit 15
```

The C45 "address" argument is encoded as `((regaddr_high << 8) | devad)` in the
upper 24 bits of the function's input — that's where the magic numbers like
`0x174001e`, `0x115001f` come from in `mts_mac_init`:
- `0x174 001e` → MMD device `0x1e`, reg-high `0x174`
- `0x115 001f` → MMD device `0x1f`, reg-high `0x115`

Devices `0x1e` and `0x1f` are Realtek vendor-specific MMDs. This is consistent
with the RTL8211/RTL8214 family.

### Bit summary

| Bit | Meaning |
|---|---|
| 15 | DONE (read 1 = transaction complete) |
| 14 | C22 READ op |
| 13 | C22 WRITE op |
| 7 | C45 READ data (`0xe0 = 0x80 | 0x60 ... wait` — actually 0xe0 = bits 7,6,5) |
| 6 | C45 WRITE data |
| 5 | C45 ADDR phase |
| 12-8 | register address (C22) / device address (C45) |
| 31-16 | data (write) / read result (read) |

(The exact bit semantics for C45 phases — bits 5/6/7 — were inferred from
the constant values `0x20`, `0x60`, `0xe0` and may need refinement against the
hardware. The first-cut driver can just hardcode the three magic constants.)

### PHY initialization sequence (from `mts_mac_init`)

After the MAC core comes out of reset, the driver does a long sequence of
Realtek-style magic pokes, abbreviated:

```c
// Standard Realtek extended-page entry pattern:
//   write reg 0x1f to "page" value 0x52b5 → switches to vendor page
//   write data registers (0x10..0x12, etc.)
//   restore reg 0x1f to original value
mts_phy_write_c22(sc, 0x1f, 0x52b5);
mts_phy_write_c22(sc, 0x11, 0xb90a);
mts_phy_write_c22(sc, 0x12, 0x006f);
mts_phy_write_c22(sc, 0x10, 0x8f82);
mts_phy_write_c22(sc, 0x1f, saved);
// ... 6 similar blocks with different (page, reg, val) triplets ...
mts_phy_write_c22(sc, 0x1f, 0x0003);
mts_phy_write_c22(sc, 0x1c, 0x0c92);
mts_phy_write_c22(sc, 0x1f, 0x0000);
```

These triplets are PHY calibration/trim values. The Linux driver can either:
1. Replicate the exact poke sequence verbatim (safest for first pass), or
2. Find a matching Realtek PHY in mainline (`drivers/net/phy/realtek.c`) and
   skip these entirely if the PHY's stock driver handles trim during reset.

Option 1 is recommended for v1 — it avoids debugging mismatches between Orbis's
custom poke sequence and mainline phylib's RTL_8211 defaults.

## DMA descriptor format

From `mts_rx_process`:
- Each software-tracking entry at `softc + 0x1858 + i*0x18` is 24 bytes:
  - `+0x00` = `bus_dmamap` cookie (or NULL if slot is free)
  - `+0x08` = struct mbuf * (or NULL)
  - `+0x10` = pointer to hardware descriptor (in coherent ring)
- Hardware descriptor first word (`*(uint32_t*)hwdesc`):
  - bit 31 = OWN — `1 = owned by HW (idle or pending TX)`, `0 = owned by driver`
  - On RX: HW clears OWN when packet arrives.
- The HW descriptor pointer's `+8` byte word gets OR'd with `0xFFFF0000` at
  ring init time, suggesting bits 16..31 of that word are something the driver
  pre-stuffs (perhaps initial length field for RX buffer).

Ring sizes:
- 256 entries per ring (loop counter is `-0x1800` and increments by `0x18` →
  256 iterations).
- 16 KB per ring at the dma_tag level (256 × ~64 bytes per HW descriptor would
  fit). Linux equivalent: allocate 256-slot coherent ring.

The exact descriptor layout beyond word 0 needs another round trip — but the
first-pass driver can prototype with a guessed layout (status + len + addr_lo +
addr_hi = 16 bytes per desc) and refine after the first packet attempt.

## Interrupt bit map

From the ISR (`mts_intr`):

| IRQ status bit | Meaning |
|---|---|
| `0x500000` | Master MAC error → reset packet engine (toggle reg 0x9c bit 6), drain TX ring, reload TX_DESC_BASE, kick RX restart bit 0 of 0x34 |
| `0x200000` | LSO_FIFO_EMPTY error (logged) |
| `0x80000`  | LSO_PRO_ERR — LSO protocol error |
| `0x40000`  | "secondary state transition" — drives reg 0x204 transition |
| `0x20000`  | RX_AXI_ERR — RX path AXI bus error |
| `0x8000`   | IP_CKS — IP checksum error |
| `0x4000`   | TCP_CKS error |
| `0x2000`   | UDP_CKS error |
| `0x1000`   | RX packet ready (kick rx softirq) |
| `0x400`    | RX_PCODE error |
| `0x100`    | (carrier) |
| `0x80`     | TX completion |
| `0x40`     | RX completion |
| `0x22`     | RX/TX restart needed → set 0x38 bit 2 |
| `0x4`      | Link state change → read 0x4 → dispatch `mts_link_change` |

For a first-pass driver we only need to handle: `0x1000` (RX), `0x80` (TX done),
`0x4` (link change). Everything else can be logged-and-cleared.

## Attach-time structural layout

The softc allocated in `mts_attach` is at least ~12 KB. Key offsets touched:
- `softc + 0x0000` = parent BUS_DMA tag
- `softc + 0x0008..0x0048` = TX/RX dma tags, maps, buffers (3 pairs of 24-byte slots before the ring)
- `softc + 0x1858..0x2058` = TX ring software tracking (256 × 24 bytes)
- `softc + 0x3058` = RX ring head index (with `+0x60` = 0x100 default tail)
- `softc + 0x3064` = RX ring tail index
- `softc + 0x3068..0x308f` = pointer to MMIO resource struct (8 bytes deep:
  `+0x00` = ?, `+0x08` = mmio_or_pio_flag, `+0x10` = base address)
- `softc + 0x30a0` = `if_dev_priv`/ifnet pointer chain
- `softc + 0x30b0..0x31b0` = various per-action mutexes (TX, RX, etc.)
- `softc + 0x30d0..0x30dd` = MAC address bytes + secondary-MAC-enable flag
- `softc + 0x30dc` = secondary MAC enabled (0/1) — driven by `node 1` registry read
- `softc + 0x30e0` = "carrier polling disabled" flag
- `softc + 0x3098` = current IRQ mask shadow
- `softc + 0x3099` = IRQ pending shadow flags (bit 4 = RX poll pending)
- `softc + 0x309c` = MAC ENABLE flag (0 = disabled, 1 = enabled, drives reg 0x204)
- `softc + 0x314c` = "GBE port enable" 0/1 (drives multicast filter loop count and reg-1c8 mask)
- `softc + 0x3180` = SMI mutex
- `softc + 0x3158` = RX softirq mutex
- `softc + 0x31a8` = link-change mutex
- `softc + 0x612` = device_t
- `softc + 0x613` = MTU shadow (init `0x1018` = 4120 = 1500 std MTU + 2620 jumbo room? Or `0x1018 = 4120` suggests 4 KB jumbo support)
- `softc + 0x615` = sysctl child pointer
- `softc + 0x60d..0x611` = bus resource handles for BAR + IRQ
- `softc + 0x616..0x645` = mutexes "network driver", "gbe:ctrl", "gbe:phy",
  "gbe:phy_ctrl", and sx-lock "gbe:rmu"

The exact softc isn't important to mimic 1:1 in Linux — but the lock topology
(separate SMI/RX/TX/link-change locks) is worth preserving.

## What sky2 was doing wrong (post-mortem of v69)

Sky2's MDIO scan polled `__gm_phy_read(hw, port, PHY_MARV_ID0, &id0)` which
internally does:
```c
gma_write16(hw, port, GM_SMI_CTRL, GM_SMI_CT_PHY_AD(addr) | GM_SMI_CT_REG_AD(reg) | GM_SMI_CT_OP_RD);
// poll GM_SMI_CT_BUSY
gma_read16(hw, port, GM_SMI_DATA);
```

`GM_SMI_CTRL` and `GM_SMI_DATA` are inside the GMAC block — sky2 computes their
address as `port_base + GM_SMI_CTRL = port_base + 0x80` where `port_base =
B2_MAC_1 + port*0x80 = 0x2800 + 0`. So sky2 reads/writes BAR+0x2880 / BAR+0x2884.

On MTS, BAR+0x2880 is unmapped or returns garbage — there's no Yukon block
there. The actual MDIO is at BAR+0x00, a totally different register layout.
That's why all 32 addresses returned `phy I/O error`: the controller status
register never set its expected "BUSY clear" bit because the wrong register
was being read.

Sky2 cannot drive MTS no matter how many quirks we stack on top. Sky2 path is
permanently dead. Patches 0001-0007 in `patches/6.x-baikal/0700-network-sky2/`
should stay disabled.

## Linux driver strategy

**Recommendation: write `drivers/net/ethernet/sony/ps4_mts.c` from scratch.**

NOT options:
- `stmmac` — DWMAC1000 register layout, doesn't match MTS. The Synopsys ID
  string in the Orbis kernel applies to USB DWC3, not the GBE.
- `sky2` — Yukon-2 register layout, proven wrong by v69.
- Realtek `r8169` / `r8125` — those are for Realtek-MAC PCIe cards; MTS uses
  a Realtek **PHY** but not a Realtek MAC.

Path forward — three phases:

### Phase 1: cold-boot bind + link detection (small new driver)
- New module `ps4_mts.ko` under `drivers/net/ethernet/sony/`
- PCI ID table: `{ PCI_VENDOR_ID_SONY, 0x90d8 }`
- `probe()`: pci_enable_device, pci_request_regions, ioremap BAR0, pci_alloc_irq_vectors(MSI)
- Implement SMI C22 read/write. Sweep PHY addr 0..31 and log Realtek PHY ID at
  PHY_ID1 = `0x001c` (RTL OUI prefix). **Must see the PHY here — if so, the
  reverse engineering is validated end-to-end.**
- Call `mts_mac_init` equivalent — replicate the register-write sequence from
  Orbis verbatim. Include the Realtek poke triplets.
- Read BAR+0x04 every second; log link status, speed, duplex.

**Pass criteria for phase 1:** with an Ethernet cable plugged into the PS4 LAN
port, `dmesg` shows `ps4_mts: link up at 1000Mbps full-duplex, PHY ID 0x001cc8XX`.
No packet TX/RX yet — just proves the MAC + PHY come up.

This phase alone solves the "is ethernet possible" question. If phase 1 passes,
ethernet on Baikal is officially possible and the remaining work is descriptor
ring plumbing.

### Phase 2: TX path
- Allocate coherent DMA ring (256 × 16 byte descriptors as a guess).
- Implement `ndo_start_xmit`:
  - Wrap skb in HW descriptor with OWN=1.
  - Bump TX tail register at BAR+0x3c/0x44.
  - Wait for TX completion IRQ (bit 0x80) and recycle.
- Pass criteria: `ping -c 1 8.8.8.8` produces an outgoing packet visible from
  a port mirror on the connected switch.

### Phase 3: RX path
- Allocate coherent DMA RX ring + per-slot skb pool.
- Implement RX NAPI poll mirroring `mts_rx_process`:
  - Walk descriptors; for each with OWN=0, hand skb to netif_receive_skb.
- Re-enable RX restart bit at BAR+0x34.
- Pass criteria: ping reply received and printed.

### Phase 4: hardening
- Promiscuous mode, multicast filter, ethtool stats, link-down handling,
  resume after error IRQs.

## Open questions for future round-trips

1. **Descriptor layout beyond word 0.** Need to look at how `mts_tx_complete`
   pulls completion status. The exact byte ordering for length, status flags,
   addr_hi, addr_lo will require another decompile pass on TX path.
2. **What does `softc + 0x30dc` mean?** It's an enable for the secondary
   MAC address AND drives whether the multicast hash filter runs 0x22 or
   0x26 entries. Could be "switch mode" vs "single port" mode.
3. **What's `gbe:rmu`?** sx_lock for some kind of "RMU" subsystem. The init
   path doesn't seem to use it — possibly only used at runtime. Future
   round-trip to look at `mts_ioctl` may reveal.
4. **The two Synopsys ID strings in the binary** (`ffffffffc8e9898d`,
   `ffffffffc8eab7b1`) have no xrefs we can find. They're probably for USB
   DWC3 (xhci_aeolia/baikal) but worth confirming so we're sure MTS is *not*
   actually DWMAC.

## Useful Ghidra anchor points (so the next session doesn't re-do this work)

```
FUN_ffffffffc85ebf10  →  mts_probe        ("Baikal GBE controller")
FUN_ffffffffc85ec030  →  mts_attach
FUN_ffffffffc85ecb60  →  mts_mac_init
FUN_ffffffffc85edcf0  →  mts_intr
FUN_ffffffffc85ee490  →  mts_smi_cl45_write
FUN_ffffffffc85ee640  →  mts_smi_cl45_read
FUN_ffffffffc85ee800  →  mts_smi_cl22_read
FUN_ffffffffc85ee910  →  mts_smi_cl22_write
FUN_ffffffffc85eea10  →  mts_rx_process
FUN_ffffffffc85eeb90  →  mts_link_change
FUN_ffffffffc85eeca0  →  mts_tx_complete  (NOT YET DECOMPILED)
FUN_ffffffffc85eed90  →  mts_rx_unwrap_one (helper for rx_process, NOT YET DECOMPILED)
FUN_ffffffffc85edcf0+offsets →  error printk slots
```

Rename these via Ghidra MCP `rename_function` before the next session to make
navigation smoother.
