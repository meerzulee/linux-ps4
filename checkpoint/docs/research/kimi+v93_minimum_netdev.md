# v93 — Minimum netdev scope for basic IP (ping/SSH/DHCP)

**kimi-k2.6, 2026-05-13**

## Executive summary

The current `ps4_mts` driver is a PCI probe stub with PHY init, ISR histogram, and link polling. It has **no `net_device`**, no TX/RX path, and no DMA buffer management. To make the already-up 1000 Mb/s link usable for basic IP, the absolute minimum featureset is surprisingly small. This document answers the 7 specific questions and defines a "v1 bring-up" scope that can be implemented in a single patch iteration.

**Reference minimal driver**: `drivers/net/ethernet/ethoc.c` (OpenCores MAC) — single queue, no checksum offload, no VLAN, no multi-queue, ~300 lines of netdev code.

---

## (1) VLAN — do we need it for basic IP?

**NO.**

VLAN tagging is handled entirely in software by the Linux networking stack (`vlan_proto.c`). The MAC does not need to know about VLANs for ping, SSH, or DHCP to work. Standard home/small-office networks do not use VLANs on the client port.

- **What the stack does**: If a packet needs a VLAN tag, the stack inserts it into the skb before calling `ndo_start_xmit`. The MAC just transmits the raw bytes.
- **What the MAC does**: On RX, the MAC receives the raw Ethernet frame (including any VLAN tag if present). The stack's VLAN layer strips it.
- **Hardware VLAN offload** (`NETIF_F_HW_VLAN_CTAG_RX/TX`) is a performance optimization, not a functional requirement.

**Verdict**: Skip VLAN entirely for v1.

---

## (2) Multicast/broadcast filter — is "promiscuous always on" enough?

**YES for v1.**

For basic IP, the stack needs to receive:
- **Broadcasts**: ARP requests, DHCP discover/offer/request/ack
- **Multicast**: IPv6 neighbor discovery (if IPv6 is enabled), IGMP
- **Unicast**: Packets addressed to our MAC

If the MAC is in promiscuous mode (receives ALL packets), the stack will filter what it wants. This is slightly inefficient but perfectly correct.

### What `ndo_set_rx_mode` needs to do in v1

```c
static void mts_set_rx_mode(struct net_device *netdev)
{
    /* v1: accept all packets. The stack filters. */
    /* Orbis sets multicast hash table via BAR+0x1bc..0x1d0.
     * For v1, we can skip this and rely on the MAC's default. */
}
```

**Later optimization**: Program the multicast hash table (BAR+0x1bc `MTS_MCAST_DATA`, 0x1c0 `MTS_MCAST_IDX`, 0x1c4 `MTS_MCAST_CTRL`, 0x1c8 `MTS_MCAST_MASK`, 0x1d0 `MTS_MCAST_DONE`) so the MAC filters multicast in hardware. But this is not needed for v1.

**Verdict**: Promiscuous/pass-all is fine for v1. Add proper filtering in v2.

---

## (3) Hardware checksum offload — skip and let stack do it?

**YES — skip entirely.**

The Linux stack computes IP, TCP, and UDP checksums in software by default. Hardware checksum offload (`NETIF_F_HW_CSUM`, `NETIF_F_IP_CSUM`, `NETIF_F_IPV6_CSUM`) is purely a performance optimization.

For a 1000 Mb/s link on a modern x86 CPU (PS4 Jaguar), software checksums are negligible overhead for basic ping/SSH traffic. Many minimal drivers (ethoc, enc28j60, ax88796) operate without checksum offload.

### What to do

- Do **not** set any checksum offload flags in `netdev->features`.
- `ether_setup()` already leaves `features = 0`.
- The stack will handle checksums transparently.

**Verdict**: Skip checksum offload for v1. Revisit when profiling shows CPU saturation.

---

## (4) TX queue requirements — single queue OK?

**YES — single queue is standard for v1.**

`alloc_etherdev()` creates a single-queue netdev by default (`tx_queue_len = DEFAULT_TX_QUEUE_LEN`, typically 1000). This is sufficient for:
- DHCP (a few packets)
- SSH (interactive, low bandwidth)
- Ping (tiny packets)

Multi-queue (`alloc_etherdev_mqs()`) is only needed for:
- High-throughput workloads that saturate a single queue
- RSS/RPS scaling across CPU cores

The MTS MAC appears to have a single TX engine (BAR+0x38 bit 0 = `MTS_ENGINE_START`). There is no evidence of multiple TX rings in the Orbis decompile.

**Verdict**: Single queue. Use `alloc_etherdev(sizeof(struct mts))`.

---

## (5) MTU — default 1500 from `ether_setup` good?

**YES — 1500 is perfect.**

`ether_setup()` sets:
```c
dev->mtu        = ETH_DATA_LEN;   // 1500
dev->min_mtu    = ETH_MIN_MTU;    // 68
dev->max_mtu    = ETH_DATA_LEN;   // 1500
```

Standard Ethernet MTU of 1500 bytes is the default for virtually all networks. No changes needed.

**Later**: If jumbo frames are needed, increase `max_mtu` and adjust descriptor buffer sizes. Not needed for v1.

**Verdict**: Use default 1500. No `ndo_change_mtu` needed for v1.

---

## (6) `ndo_set_mac_address` — hardcode from EEPROM/efuse or random?

**Either works for v1. Random locally-administered is the fastest path.**

The MAC address must be:
1. **Unique** on the local Ethernet segment (no duplicates).
2. **Valid** — bit 0 of first byte = 0 (unicast), bit 1 = 1 (locally administered) is fine.

### Options ranked by preference

| Method | Complexity | Correctness for v1 |
|---|---|---|
| Read from efuse/EEPROM/BIOS | Medium — need to know where Sony stores it | Best |
| Derive from PCI BDF + fixed OUI | Low — e.g., `00:19:c5:00:<bus>:<devfn>` | Good |
| `eth_random_addr()` | Lowest — one function call | Fine for v1 testing |

### Recommended v1 approach

```c
/* If we can read the real MAC from somewhere, use it.
 * Otherwise, generate a random locally-administered address. */
if (mts_read_mac_from_efuse(mts, addr)) {
    eth_hw_addr_set(netdev, addr);
} else {
    eth_hw_addr_random(netdev);
    dev_info(&pdev->dev, "MAC address not found in efuse, using random %pM\n",
             netdev->dev_addr);
}
```

The PS4's bootloader or Orbis likely has the MAC in efuse or SMI EEPROM. For v1, `eth_hw_addr_random()` is acceptable. For production, we should find the real MAC.

**Verdict**: Implement `ndo_set_mac_address` as a simple wrapper around `eth_hw_addr_set()`. For probe, try to read real MAC, fall back to random.

---

## (7) Simplest skb→descriptor mapping that won't corrupt memory

This is the most critical part. Based on Orbis `mts_init_rings_kick` (`0xc85ef1b0`) decompile and the existing `ps4_mts` probe code.

### What we know from Orbis

1. **Descriptor size**: 16 bytes (0x10).
2. **Ring size**: 256 entries (Orbis loops 0x1000 / 0x10 = 256).
3. **RX descriptor layout** (inferred from decompile):
   - offset 0x00: `uint32` status/owner word
     - Bit 31 = 1: MAC owns the descriptor (can receive into it)
     - Bit 31 = 0: Driver owns (packet ready for stack)
   - offset 0x04: `uint32` buffer address LOW (or segment info)
   - offset 0x08: `uint32` buffer address HIGH / length
     - Orbis ORs this with `0xffff0000` during init
   - offset 0x0c: `uint32` reserved / next pointer

4. **TX descriptor layout** (inferred from decompile):
   - offset 0x00: `uint32` control word
     - Bit 31 = 1: MAC owns (can transmit)
     - Bit 30 = 1: Last descriptor in packet (`0x40000000`)
     - Bits 10:9 = segment type? (`0x00000600`)
   - offset 0x04: `uint32` length / segment info
   - offset 0x08: `uint32` buffer address LOW
   - offset 0x0c: `uint32` buffer address HIGH

5. **Buffer size**: Orbis uses 0x600 (1536) bytes per buffer for TX. RX likely similar.

### Simplest safe v1 mapping

**Design principle**: One skb = one descriptor. No scatter-gather. No jumbo frames. No chaining.

#### RX ring (256 entries)

```c
struct mts_desc {
    u32 ctrl;      /* owner, status, length */
    u32 buf_lo;    /* buffer address low */
    u32 buf_hi;    /* buffer address high */
    u32 reserved;  /* Orbis leaves this at 0xffff0000 init for RX */
};

#define MTS_NUM_RX_DESC  256
#define MTS_NUM_TX_DESC  256
#define MTS_BUF_SIZE     2048   /* > 1518 + headroom, power of 2 */
```

**RX setup**:
1. Allocate `MTS_NUM_RX_DESC * MTS_BUF_SIZE` bytes of DMA-coherent memory (or `MTS_NUM_RX_DESC` individual pages).
2. For each descriptor:
   - `desc->ctrl = 0x80000000` (MAC owns)
   - `desc->buf_lo = lower_32_bits(dma_addr)`
   - `desc->buf_hi = upper_32_bits(dma_addr)`
   - `desc->reserved = 0xffff0000` (matches Orbis)
3. Program ring base to BAR+0x40/0x48 (RX lo/hi).

**RX processing** (in NAPI poll):
1. Check descriptor `ctrl` — if bit 31 is clear, the MAC has received a packet.
2. Read the packet length from `ctrl` (lower bits or bits [15:0] of offset 0x08).
3. `dma_sync_single_for_cpu()` on the buffer.
4. `build_skb()` or `netdev_alloc_skb_ip_align()` + `memcpy` into a new skb.
   - *Alternative*: Use `page_frag` or reuse the DMA buffer directly with `build_skb()`.
5. Refill the descriptor with a new buffer and set bit 31 = 1.

**Simplification for v1**: Use `skb_copy_to_linear_data()` or just `netdev_alloc_skb_ip_align()` + `skb_put()` + `memcpy`. It's not the most efficient but it's the safest and easiest to debug.

#### TX ring (256 entries)

**TX setup**:
1. Allocate descriptor ring only (no pre-allocated buffers needed).
2. After init, all descriptors have bit 31 = 0 (driver owns empty slots).

**TX processing** (`ndo_start_xmit`):
1. Find next free descriptor (bit 31 = 0).
2. `dma_map_single(skb->data, skb->len, DMA_TO_DEVICE)` → get DMA address.
3. Store `(skb, dma_addr)` in a driver-side `tx_skb[desc_idx]` array.
4. Fill descriptor:
   - `desc->ctrl = 0x00000600 | (last ? 0x40000000 : 0)` — bit 31 = 0 initially
   - `desc->buf_lo = lower_32_bits(dma_addr)`
   - `desc->buf_hi = upper_32_bits(dma_addr)`
   - `desc->len_or_seg = skb->len` (or segment info)
5. **Memory barrier**: `wmb()` before setting owner bit.
6. Set bit 31 = 1: `desc->ctrl |= 0x80000000` (hand to MAC).
7. Kick TX engine: `writel(readl(bar + MTS_TX_KICK) | 1, bar + MTS_TX_KICK)`.
8. Return `NETDEV_TX_OK`.

**TX completion** (in NAPI poll or ISR):
1. Check descriptor `ctrl` — if bit 31 is clear, MAC is done.
2. Look up `tx_skb[desc_idx]`.
3. `dma_unmap_single(dma_addr, len, DMA_TO_DEVICE)`.
4. `dev_kfree_skb_any(skb)`.
5. Mark descriptor as free (bit 31 = 0).

### Critical safety rules

1. **Never let the MAC write past buffer end**: Always allocate buffers ≥ 2048 bytes. The MTU is 1500, so 2048 is safe.
2. **Sync DMA before CPU access**: `dma_sync_single_for_cpu()` before reading RX data. `dma_sync_single_for_device()` before handing TX to MAC.
3. **Memory barriers**: `wmb()` before writing owner bit to descriptor. `rmb()` after reading owner bit.
4. **Stop queue when ring is full**: `netif_stop_queue()` when no free TX descriptors. Wake with `netif_wake_queue()` on completion.
5. **No scatter-gather for v1**: If `skb->len > MTS_BUF_SIZE` or `skb_shinfo(skb)->nr_frags > 0`, fall back to `skb_linearize()` or drop the packet.

### Why this won't corrupt memory

- **Fixed-size ring**: No dynamic allocation in the hot path.
- **DMA-coherent or explicitly synced**: The CPU and MAC agree on buffer state.
- **Single-segment**: No complex chaining that could go wrong.
- **Length validation**: `skb->len` is checked against buffer size before mapping.
- **No recursion**: NAPI poll is bounded by `budget`.

---

## MUST HAVE vs CAN SKIP — summary table

| Feature | Status | Rationale |
|---|---|---|
| `alloc_etherdev()` + `register_netdev()` | **MUST** | Required for any IP traffic |
| `ndo_open` / `ndo_stop` | **MUST** | Start/stop engines, enable/disable IRQ/NAPI |
| `ndo_start_xmit` | **MUST** | Transmit path for ARP replies, DHCP, SSH responses |
| RX NAPI poll | **MUST** | Receive path for ARP, DHCP, incoming SSH/ping |
| ISR → NAPI schedule | **MUST** | Hardware IRQ → software processing |
| MAC address (any valid) | **MUST** | Required for Ethernet frame source address |
| `ndo_set_mac_address` | **MUST** | `ip link set dev eth0 address ...` |
| DMA descriptor rings (TX+RX) | **MUST** | Hardware requires them |
| `netif_carrier_on/off` | **MUST** | Tell stack when link is up/down |
| Single TX queue | **MUST** | Default, sufficient for v1 |
| MTU 1500 (default) | **MUST** | `ether_setup()` already sets this |
| `ndo_set_rx_mode` (promiscuous) | **CAN SKIP** | Implement as no-op; MAC default may pass all |
| VLAN offload | **CAN SKIP** | Stack handles VLAN in software |
| Hardware checksum offload | **CAN SKIP** | Stack computes checksums |
| Scatter-gather (NETIF_F_SG) | **CAN SKIP** | `skb_linearize()` for rare fragmented skbs |
| TSO/GSO/GRO | **CAN SKIP** | Not needed for basic traffic |
| Multicast hash table | **CAN SKIP** | Promiscuous mode handles it |
| `ndo_change_mtu` | **CAN SKIP** | 1500 is fine for v1 |
| `ndo_do_ioctl` | **CAN SKIP** | MII ioctl handled by generic PHY layer or ethtool |
| `ndo_tx_timeout` | **CAN SKIP** | Nice to have, but not required for basic IP |
| `ndo_validate_addr` | **CAN SKIP** | Default implementation is fine |
| Statistics (`ndo_get_stats64`) | **CAN SKIP** | Useful for debugging, not required |
| ethtool ops | **CAN SKIP** | Helpful for `ethtool -S`, not required for ping/SSH |
| PHYLIB integration | **CAN SKIP** | Our driver already does direct SMI; can report link=up manually |
| Pause frame / flow control | **CAN SKIP** | Not needed for basic IP on a quiet network |
| Wake-on-LAN | **CAN SKIP** | Obviously not needed |

---

## Recommended v1 implementation plan

One patch, estimated ~400 lines added to `ps4_mts.c`:

1. **Add `struct net_device *netdev` to `struct mts`**.
2. **Implement `ndo_open`**:
   - `napi_enable()`
   - Set MAC address to BAR+0x14/0x18 if not already done
   - `netif_carrier_on()` (link is already up)
   - `netif_start_queue()`
3. **Implement `ndo_stop`**:
   - `netif_stop_queue()`
   - `napi_disable()`
   - `netif_carrier_off()`
4. **Implement `ndo_start_xmit`**:
   - Simple single-segment TX as described above
5. **Implement NAPI poll**:
   - RX: check descriptors, build skbs, hand to `netif_receive_skb()`
   - TX: complete descriptors, unmap, free skbs
   - Refill RX descriptors
6. **Implement `ndo_set_mac_address`**:
   - `eth_hw_addr_set()` + write to BAR+0x14/0x18
7. **Add `net_device_ops` and register in `mts_probe`**:
   - `alloc_etherdev(sizeof(struct mts))`
   - Set MAC address
   - `register_netdev()`
8. **Wire ISR to schedule NAPI** instead of just histogramming.

**No changes needed to**: PHY init, SMI accessors, kthread, link poll, IRQ registration, DMA ring allocation. All existing code stays.

---

## References

| Source | Relevance |
|---|---|
| `drivers/net/ethernet/ethoc.c` | Minimal netdev reference: single queue, no offload, simple ring buffer |
| `drivers/net/ethernet/sony/ps4_mts.c` (current) | Existing probe/PHY/ISR code; rings already allocated |
| Orbis `mts_init_rings_kick` (`0xc85ef1b0`) | Descriptor ring init, 16-byte descriptors, ownership bits |
| `include/linux/etherdevice.h` | `alloc_etherdev()`, `eth_hw_addr_random()`, `eth_hw_addr_set()` |
| `include/linux/netdevice.h` | `net_device_ops`, `napi_struct`, `netif_carrier_on/off` |
| `net/ethernet/eth.c:345` | `ether_setup()` defaults (MTU 1500, broadcast/multicast flags) |

---

## Bottom line

For basic ping/SSH/DHCP over a confirmed-up 1000 Mb/s link, the netdev requirements are minimal:

- **One TX queue, one RX ring, 256 descriptors each.**
- **No VLAN, no checksum offload, no TSO, no GRO.**
- **Promiscuous RX is fine for v1.**
- **Single-segment descriptor mapping with explicit DMA sync is the safest path.**
- **A random MAC address is acceptable for v1 testing.**

The complexity is not in the featureset — it's in getting the descriptor ownership handoff and DMA sync correct. The hardware is already proven to work; we just need to pipe packets through it.
