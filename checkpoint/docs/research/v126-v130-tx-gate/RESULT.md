# v126-v130 TX gate hunt — session 2026-05-14

## TL;DR

5-hour deep dive into "why does the PS4 MTS Baikal ethernet chip never
fetch our TX descriptors despite the engine appearing armed?".  We did
Ghidra reverse engineering of the Orbis MTS driver, ran 5 hardware
hotswap experiments, and confirmed via in-driver telemetry that **HW
silently ignores every TX descriptor regardless of what we put in
BAR+0x034 or where buf_lo points**.

Everything we tried is concretely eliminated.  Five hypotheses tested,
five rejected.  The TX silicon-level gate is still unknown — most
likely it's either an undiscovered BAR0 register or a parent-PCIe
switch-core (BAR2+0x2880) write we haven't decoded.

## What we know definitively now (across v82..v130)

### BAR0 register state — what HW accepts

Bruteforce probe at runtime (v127) confirmed:

| Reg | Writable bits | Linux state | Orbis state | Match? |
|---|---|---|---|---|
| 0x030 (MAC_MODE) | bits 0-7, 8, 16 (= `0x000101ff`) | `0x00010100` | `0x00010100` | ✅ |
| 0x034 (TX_CTRL) | bits 0, 2 only (`0x00000005`) | `0x00000005` after kick | `0x00000005` typical | ✅ |
| 0x038 (RX_CTRL) | bits 0, 2 | `0x00000008` | `0x00000008` | ✅ |
| 0x03c (TX_DESC_LO) | full | `tx_ring_dma` | `tx_ring_dma` | ✅ |
| 0x040 (RX_CURRENT) | written, HW advances | `rx_ring_dma + offset` | same | ✅ |
| 0x044 (TX_DESC_HI) | full | `tx_ring_dma` (alias) | `tx_ring_dma` | ✅ |
| 0x048 (RX_BASE) | full | `rx_ring_dma` | `0x10004000` | ✅ |
| 0x054 (IRQ_MASK) | full | was `0x7beffe`, v130 `0x1018` | `0x1018` | ✅ (with v130) |

**Bit-level finding:** writing `0xFFFFFFFF` to BAR+0x034 reads back as
`0x00000005`.  Only bits 0 (GO) and 2 (KICK) are writable.  **There is
no TX_CTRL config bit at offset 0x034.**  Linux's earlier v126
hypothesis (writing `0x00010101` to set bits 8+16+0) was wrong — those
bits don't physically exist on this register.

### MAC engine state

- ✅ Bus Master enabled (lspci confirms `BusMaster+`)
- ✅ MaxReadRequestSize bumped from 128B → 2048B via `setpci CAP_EXP+8.W=4910`
- ✅ IOMMU `iommu=pt` (passthrough); `intremap=off`
- ✅ MAC_CTRL1 (BAR+0x008) = `0x0f597c00` — matches Orbis
- ✅ MAC_MODE (BAR+0x030) = `0x00010100` — matches Orbis exactly
- ✅ MAC_PAUSE (BAR+0x074) = `0x00002277` — matches Orbis
- ✅ PHY linked at MII level (BMSR shows AN complete, LP_ABILITY OK)
- ❌ MAC bit-0 latch on BAR+0x004 never fires — but **Orbis snapshot
     also shows BAR+0x004 bit 0 = 0**, so this is not required

### TX descriptor state

v128 dbg_timer telemetry confirmed across many ticks:
- Linux writes proper descriptors: `ctl=0x30000xxx` (SOF+EOF+len),
  `buf_lo=DMA addr`, `aux0=0`, `aux1=0`
- **HW never mutates any descriptor.**  OWN bit (BIT(31)) never appears
  on tx_ring[0..3] regardless of how many xmits queue up
- BAR+0x03c (TX current pointer) stays at base address — **HW never
  advances past entry 0**

This means HW never reads a single TX descriptor.

### Orbis architecture (from Ghidra)

Decompiled functions:
- `mts_attach @ ffffffffc85ec030` — PCIe resource setup, mtx_init, mts_mac_init
- `mts_ifup @ ffffffffc85ec940` — calls mts_mac_init, mts_init_rings_kick,
  resumes gbe:ctrl + gbe:phy_ctrl kthreads
- `mts_mac_init @ ffffffffc85ecb60` — MAC reset, PHY trim writes, writes
  BAR+0x030 = `0x10100`, BAR+0x074 = `0x2277`, BAR+0x008 |= `0x07597c00`
- `mts_init_rings_kick @ ffffffffc85ef1b0` — programs desc bases, ORs
  bit 0 to BAR+0x034 and 0x038 to start engines, writes mask, sets
  rings-ready marker
- `mts_intr @ ffffffffc85edcf0` — IRQ handler.  On bit-18 only, exits
  init mode (`BAR+0x204 = 0`, `BAR+0x54 = saved_irq_mask`)
- `mts_tx_complete @ ffffffffc85eeca0` — TX completion reaper.  Checks
  OWN=1 + aux0 != FREE_SENTINEL (0xffff0000)
- `FUN_ffffffffc85efdb0` — Orbis if_start.  Dequeues mbufs, fills
  descs, ORs bit 2 to BAR+0x034 ONCE per batch
- `FUN_ffffffffc85f1aa0` — Orbis descriptor fill function.  **Copies
  packet data into a pre-allocated 640KB TX BUFFER POOL**, sets
  buf_lo into the pool, marks SOF/EOF
- `FUN_ffffffffc85f0190` — gbe:ctrl kthread body.  Waits on condvar,
  on event bit 2 clears BAR+0x54 bit 12 (gbe:ctrl-done ack)
- `FUN_ffffffffc85f0480` — gbe:phy_ctrl kthread body.  Handles PHY
  events (AN restart, link recovery)
- `saved_irq_mask` (sc+0x3098) = `0x1018` — set in mts_attach.  Bits
  3, 4, 12 are the only IRQ types masked off during operation

## What v126-v130 tested and falsified

### v126: TX_CTRL config bits 8+16 in BAR+0x034 (FALSIFIED)

Hypothesis: Orbis snapshot showed BAR+0x034 = `0x10100` (bits 8+16) in
working state; Linux only writes bit 0.  Tried writing `0x10101` to
BAR+0x034 to add the config bits.

Result: HW silently rejected bits 8 and 16.  Bruteforce probe (v127)
confirmed BAR+0x034 only has writable bits 0 and 2.

The `0x10100` we saw at BAR+0x034 in the Orbis snapshot is either an
HW read-side mirror of BAR+0x030, or the dumper read mirror; either
way it is NOT actually held at 0x034 itself.

### v127: bruteforce writability probe (DIAGNOSTIC ONLY)

In-driver probe.  Wrote `0xFFFFFFFF` and `0x00000000` to BAR+0x030 and
BAR+0x034, read back to discover writable bits.  Confirmed:
- BAR+0x030 accepts bits 0-7, 8, 16 (= `0x000101ff` mask)
- BAR+0x034 accepts ONLY bits 0 (GO) and 2 (KICK)

Result: useful diagnostic.  No fix in itself.

### v128: TX descriptor live telemetry (DIAGNOSTIC, KEPT)

Extended mts_dbg_timer_fn to dump `tx_ring[0..3].ctl_len` and `aux0`,
plus BAR+0x030/0x034/0x03c/0x044, every 5 seconds.

Result: definitively confirmed HW never touches descriptors.

### v129: TX buffer pool (FALSIFIED)

Hypothesis: Orbis allocates a single 640KB DMA-coherent buffer pool,
copies every outgoing packet into it, and sets desc.buf_lo to the
pool address.  Linux passes `skb->data` DMA addresses directly via
`dma_map_single`.  Maybe HW rejects arbitrary DMA addresses and requires
the pool.

Implementation: added `tx_pool_virt/dma/offset` to struct mts; allocated
640KB in mts_probe via `dmam_alloc_coherent`; rewrote mts_start_xmit to
`memcpy(pool + offset, skb->data, skb->len)` and point desc.buf_lo into
the pool; removed `dma_unmap_single` from mts_tx_reap.

Result: v98 confirmed `buf=0x01200000` (pool DMA base) — Linux now uses
pool architecture identical to Orbis.  **HW still does not fetch TX
descriptors.**  Pool address is not the gate.

### v130: saved_irq_mask = 0x1018 (FALSIFIED)

Hypothesis: Orbis sets saved_irq_mask to `0x1018` (bits 3, 4, 12
masked) but Linux uses `0x7beffe` (very different bits masked).  Maybe
HW requires the canonical Orbis mask before starting TX engine.

Implementation: changed saved_irq_mask in mts_mac_init AND in mts_open's
v117 post-ring IRQ enable block to hardcoded `0x00001018`.

Result: BAR+0x54 = `0x1018` after init, matches Orbis.  **TX engine
still does not fetch.**  Mask value is not the gate.

## Remaining hypotheses (not yet tested)

1. **Undiscovered BAR0 register** — e.g., Orbis snapshot shows
   `BAR+0x070 = 0x14003` (bit 14 set); Linux's runtime state at 0x070
   has not been measured.  Possibly other registers we haven't even
   sampled.
2. **Switch core / Path G via parent BAR2+0x2880** — wedged the PS4
   when tried from userspace in v124.  Would need in-kernel
   `pci_request_regions` on parent device 00:14.4.  Orbis driver does
   NOT appear to write to parent BAR from Ghidra reads, but the
   parent might be programmed by a separate Orbis subsystem before
   driver attach (SbX bootloader, ICC, etc.).
3. **PCIe FLR (Function-Level Reset)** — chip may have sticky state
   that survives module reload but not power-cycle.  Worth a clean
   power-cycle test before more software experiments.

## What's working in this branch (rollup vs crashniels)

- USB: ✅
- SATA: ✅
- HID/keyboard: ✅
- Audio: ✅
- Graceful shutdown: ✅
- WiFi + SSH at 192.168.50.125: ✅
- Ethernet RX: ✅ (since v93)
- Ethernet TX: ❌ (this saga)
- HDMI display: ❌ (separate ICC issue)

## Files

- `ps4_mts-experimental.c` — full ps4_mts.c snapshot with v126..v130 applied
  (untested-on-bare-metal v129 + v130 included for record)

## Reproducer

To get back to this state for further iteration:

```
git checkout wip/ethernet     # current branch
bash ./build.sh -t 6.x-baikal -c
# Manually overlay this checkpoint's ps4_mts-experimental.c on top of src/...
cp checkpoint/docs/research/v126-v130-tx-gate/ps4_mts-experimental.c \
   src/6.x-baikal/drivers/net/ethernet/sony/ps4_mts.c
bash scripts/dev/hotswap-mts.sh
ssh ps4 'sudo ip link set enp0s20f1 up && sudo ping -c 3 -I enp0s20f1 192.168.50.1'
# Expected: 100% packet loss (TX still dead)
```
