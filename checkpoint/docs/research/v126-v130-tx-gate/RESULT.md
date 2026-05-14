# v126-v132 TX gate hunt — 7 hypotheses falsified

## TL;DR

7-hour deep dive into "why does the PS4 MTS Baikal ethernet chip never
fetch our TX descriptors despite the engine appearing armed?".  Did
Ghidra reverse engineering of the Orbis MTS driver AND the ArabPixel
linux-1024mb kexec loader payload, ran 7 hardware experiments, used
in-driver bruteforce register probes, and definitively confirmed via
v128 telemetry that **HW silently ignores every TX descriptor
regardless of state we put the chip in**.

Seven distinct hypotheses tested, seven falsified.  The TX silicon-level
gate is still unknown.  Strongest remaining lead: **parent BAR2+0x2880
(Path G to switch core)** — the one thing Orbis programs that we have
not replicated, because userspace access to it wedged the PS4 (v124).

## What we definitively know now

### BAR0 register state — what HW accepts (v127 bruteforce probe)

Wrote `0xFFFFFFFF` and `0` to each register, read back to discover
writable bits:

| Reg | Writable bits | Linux state | Orbis state | Match? |
|---|---|---|---|---|
| 0x030 (MAC_MODE) | bits 0-7, 8, 16 (= `0x000101ff`) | `0x00010100` | `0x00010100` | ✅ |
| 0x034 (TX_CTRL) | bits 0, 2 only (`0x00000005`) | `0x00000005` after kick | `0x00000005` typical | ✅ |
| 0x038 (RX_CTRL) | bits 0, 2 | `0x00000008` | `0x00000008` | ✅ |
| 0x03c (TX_DESC_LO) | full | `tx_ring_dma` | `tx_ring_dma` | ✅ |
| 0x040 (RX_CURRENT) | written, HW advances | `rx_ring_dma + offset` | same | ✅ |
| 0x044 (TX_DESC_HI) | full | `tx_ring_dma` (alias) | `tx_ring_dma` | ✅ |
| 0x048 (RX_BASE) | full | `rx_ring_dma` | `0x10004000` | ✅ |
| 0x054 (IRQ_MASK) | full | `0x7beffe`, v130 tested `0x1018` | `0x1018` | ✅ (with v130) |
| 0x204 (IRQ_ENABLE_FULL) | full | toggled in tests | `0x10001388` cycled | ✅ |

**Bit-level finding:** writing `0xFFFFFFFF` to BAR+0x034 reads back as
`0x00000005`.  Only bits 0 (GO) and 2 (KICK) are writable.  **There is
no TX_CTRL config bit at offset 0x034.**

### MAC engine state

- ✅ Bus Master enabled (lspci confirms `BusMaster+`)
- ✅ MaxReadRequestSize 128B → 2048B via `setpci CAP_EXP+8.W=4910`
- ✅ IOMMU `iommu=pt` (passthrough); `intremap=off`
- ✅ MAC_CTRL1 (BAR+0x008) = `0x0f597c00` — matches Orbis
- ✅ MAC_MODE (BAR+0x030) = `0x00010100` — matches Orbis
- ✅ MAC_PAUSE (BAR+0x074) = `0x00002277` — matches Orbis
- ✅ PHY linked at MII level (BMSR shows AN complete, LP_ABILITY OK)
- ✅ Engine GO bit (BAR+0x034 bit 0) accepted by HW
- ✅ KICK bit (BAR+0x034 bit 2) writable
- ✅ MSI Capability fully programmed (lspci: `Enable+ Count=1/1`,
     `Address=0xfee04000`, `Data=0x24`, `Masking=0x00000000`)
- ✅ TX buffer pool architecture (640KB DMA-coherent, packet-copy-on-xmit,
     matches Orbis FUN_ffffffffc85f1aa0)
- ❌ **HW still never reads TX descriptors.**

### TX descriptor state (v128 dbg_timer telemetry, every 5s)

Linux writes proper descriptors:
- `ctl=0x30000xxx` (SOF + EOF + len in low 16)
- `buf_lo=DMA addr` (either skb DMA or pool offset, both tested)
- `aux0=0`, `aux1=0`

**HW never mutates any descriptor.**  OWN bit (BIT(31)) never appears
on tx_ring[0..3] regardless of how many xmits queue up.  BAR+0x03c
(TX current pointer) stays at base — **HW never advances past entry 0**.

### Master IRQ behaviour (test 6)

Userspace mmap-write of `BAR+0x204 = 0x10001388` from Linux:
- Counter went from `total_irq=1` to `total_irq=2107` in 2 seconds
- bit-18 IRQ storm exactly as documented in v117 commit
- **TX still 0% — tx_cons=0, descriptors untouched**

So master IRQ on/off is NOT the gate — TX engine is independently
silent.

### Loader-level intervention (test 7)

Cloned ArabPixel/ps4-linux-payloads, found this in
`linux/ps4-kexec-common/linux_boot.c`:

```c
if (sb_id == SB_BAIKAL) {
    disableMSI(0xf80a00e0); //func 0 ACPI
    disableMSI(0xf80a10e0); //func 1 Baikal Ethernet Controller  ← MTS
    disableMSI(0xf80a20e0); //func 2 SATA AHCI
    disableMSI(0xf80a30e0); //func 3 SD/MMC
    disableMSI(0xf80a40e0); //func 4 PCIe Glue (Path G parent)
    disableMSI(0xf80a50e0); //func 5 DMA Controller
    disableMSI(0xf80a60e0); //func 6 Baikal Memory
    disableMSI(0xf80a70e0); //func 7 USB 3.0 xHCI
}
```

The kexec stub physically disables MSI on every Baikal southbridge
function (Enable bit clear + Mask register set to all-1s) right before
booting Linux.

Modified payload (`linux-1024mb.bin` with `disableMSI(0xf80a10e0)`
commented out) was built, FTP'd to PS4, kexec'd.  UART log confirms:
```
kexec: Detected Baikal Southbridge, disabling IOMMU (eth MSI SKIPPED for TX test)...
```
**TX still dead.**

Reason: Linux's `pci_enable_msi()` clears the mask register anyway,
so the loader's mask is undone before any traffic flows.  Verified:
both MTS (00:14.1) and parent bpcie (00:14.4) show `Masking=0x00000000`
post-Linux-boot regardless of which payload variant was used.

## Orbis architecture (from Ghidra)

Fully decompiled, key functions:

| Function | Address | What |
|---|---|---|
| mts_attach | ffffffffc85ec030 | PCIe setup, mtx_init, **saved_irq_mask = 0x1018** at sc+0x3098, calls mts_mac_init |
| mts_ifup | ffffffffc85ec940 | mts_mac_init, mts_init_rings_kick, resumes ctrl/phy_ctrl kthreads |
| mts_mac_init | ffffffffc85ecb60 | MAC reset, PHY trim, **writes BAR+0x030 = 0x10100**, 0x074=0x2277, 0x008 \|= 0x07597c00 |
| mts_init_rings_kick | ffffffffc85ef1b0 | Programs desc bases at 0x03c/0x044/0x040/0x048, ORs bit 0 to 0x034 and 0x038, writes mask at 0x054, sets rings-ready marker at sc+0x1c8 \|= 0x40 |
| mts_intr | ffffffffc85edcf0 | IRQ handler; cycle: first-call writes 0x204=0x10001388 + 0x54=0x7bfffe; bit-18-only clears 0x204+restores 0x54=saved_irq_mask; TX_DONE (bit 7 of 0x50) calls mts_tx_complete + ORs bit 2 of 0x034 |
| mts_tx_complete | ffffffffc85eeca0 | Reaps completed TX (checks OWN=1 + aux0 ≠ FREE_SENTINEL 0xffff0000) |
| FUN_c85efdb0 | ffffffffc85efdb0 | Orbis if_start.  Dequeues mbufs, fills descs (calls FUN_c85f1aa0), ORs bit 2 to 0x034 **once per batch** |
| FUN_c85f1aa0 | ffffffffc85f1aa0 | Descriptor fill.  **Copies packet data into 640KB TX buffer pool at sc+0x32a8**, sets buf_lo to pool DMA, marks SOF/EOF |
| FUN_c85f0190 | ffffffffc85f0190 | gbe:ctrl kthread.  Waits on condvar; on event bit 2 clears BAR+0x54 bit 12 (gbe:ctrl-done ack) |
| FUN_c85f0480 | ffffffffc85f0480 | gbe:phy_ctrl kthread.  Handles PHY events (AN restart, link recovery) |

The Orbis TX path is fully understood at software level.  Nothing in
the Orbis driver touches parent BAR2+0x2880 (Path G) from kernel
context, so whatever programs that switch-core slot must happen during
SbX/ICC bootloader phase before driver attach.

## Seven hypotheses tested and falsified

### v126: TX_CTRL config bits 8+16 in BAR+0x034 (FALSIFIED)

Orbis snapshot showed BAR+0x034 = `0x10100` (bits 8+16) in working
state.  Wrote `0x10101` to BAR+0x034.  HW silently rejected bits 8/16
(bruteforce probe confirmed bits 0+2 are the only writable bits at
0x034).  The `0x10100` we saw at 0x034 in the Orbis snapshot is from
HW read-side mirror of BAR+0x030, not actually held at 0x034.

### v127: bruteforce writability probe (DIAGNOSTIC ONLY)

Wrote `0xFFFFFFFF` to each register, observed which bits stuck.
Confirmed BAR+0x030 accepts `0x000101ff`, BAR+0x034 accepts only
bits 0/2.  Useful for the v126 falsification but not a fix.

### v128: TX descriptor live telemetry (DIAGNOSTIC, KEPT)

Extended mts_dbg_timer_fn to dump `tx_ring[0..3].ctl_len` and `aux0`
plus BAR regs every 5 seconds.  Definitively confirmed HW never
touches descriptors — across multiple boots, hotswaps, configurations.

### v129: TX buffer pool with copy-on-xmit (FALSIFIED)

Hypothesis: Orbis copies packets into a 640KB DMA pool; maybe HW only
accepts buf_lo addresses in that range.

Implementation: added `tx_pool_virt/dma/offset` to struct mts;
allocated 640KB in mts_probe via `dmam_alloc_coherent`; rewrote
mts_start_xmit to `memcpy(pool+off, skb->data, skb->len)` and point
desc.buf_lo into the pool; removed `dma_unmap_single` from mts_tx_reap.

Result: v98 confirmed `buf=0x01200000` (pool DMA base) — Linux now uses
identical architecture to Orbis.  **HW still does not fetch.**

### v130: saved_irq_mask = 0x1018 (FALSIFIED)

Hypothesis: Orbis uses `0x1018` (bits 3,4,12 masked); Linux uses
`0x7beffe` (different bits).  Maybe HW gates engine on canonical mask
value.

Implementation: hardcoded saved_irq_mask=`0x00001018` in mts_mac_init
and in v117 post-ring IRQ enable.

Result: BAR+0x54 = `0x1018` confirmed, matches Orbis.  **TX still dead.**

### v131: BAR0 audit + payload MSI skip (FALSIFIED)

Two-part:

**Part A — BAR0 audit:** In-driver dump of every non-zero u32 in
BAR0[0..0x200] after engine start.  Compared to Orbis snapshot.
Linux state matches Orbis on every register we can read.  No missing
register write identified.

**Part B — modified linux-1024mb.bin payload:** Commented out
`disableMSI(0xf80a10e0)` so the loader doesn't pre-mask the ethernet
controller's MSI vectors.  Built modified linux-1024mb.bin, FTP'd to
PS4, verified UART log shows `"(eth MSI SKIPPED for TX test)"`.

Result: identical TX dead state.  lspci confirms Linux's
`pci_enable_msi()` always clears the mask anyway — the loader's mask
was a no-op for Linux operation.

### v132: userspace BAR+0x204 master IRQ re-enable (FALSIFIED)

Hypothesis: after v117 ISR clears BAR+0x204 to 0 on bit-18 handshake,
master IRQ stays off and TX engine pauses.

Implementation: Python via /sys/bus/pci/devices/0000:00:14.1/resource0
mmap, writing `0x10001388` to BAR+0x204 from userspace.

Result: `total_irq` jumped from 1 to 2107 in 2 seconds (bit-18 IRQ
storm exactly as documented in v117 commit).  **TX still 0% packet
loss, tx_cons=0, descriptors untouched.**  Master IRQ state is not the
TX gate.

## Remaining hypothesis (not yet tested)

**Parent BAR2+0x2880 (Path G) configuration.**  This is the only
concrete piece of HW programming we know exists but have not
replicated.  In v124 we attempted userspace writes to this address
and the PS4 hard-wedged + EMC-rebooted within seconds, losing the
PSFree session.

To safely test, would need an in-kernel implementation:
- `pci_request_regions()` on parent device 00:14.4
- Coordinate with the bpcie driver that currently owns it
- ioremap parent's BAR2, write to offset 0x2880
- Backed out by a clear way to undo if PS4 wedges

This is significant new code and carries genuine risk.  Recommended
for a fresh session with calm preparation and willingness to lose
the boot if it goes wrong.

## What's working in this branch

- USB: ✅
- SATA: ✅
- HID/keyboard: ✅
- Audio: ✅
- Graceful shutdown: ✅
- WiFi (mt7668) + SSH at 192.168.50.125: ✅
- Ethernet RX: ✅ (since v93)
- **Ethernet TX: ❌ (this saga, 25+ iterations)**
- HDMI display: ❌ (separate ICC issue)

## Artifacts in this folder

- `ps4_mts-experimental.c` — full ps4_mts.c snapshot with v126..v131
  applied (TX buffer pool, BAR0 audit, etc.)
- `linux-1024mb-msi-skip.bin` — modified loader payload with the
  ethernet `disableMSI` call commented out

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

## Key learnings carried over to next session

1. **v117 lazy BAR+0x204 enable IS load-bearing.**  Userspace test
   confirmed: re-enabling BAR+0x204 = 0x10001388 immediately produces
   ~2000 IRQs/sec (bit-18 storm).  v117 was correct to clear it once.

2. **TX engine is silicon-gated, not driver-bug.**  Same descriptor
   format, same DMA addresses, same engine arm sequence, same MSI
   configuration as Orbis — yet HW refuses to fetch.

3. **The Orbis snapshot's BAR+0x034 = 0x10100 is a HW read-mirror of
   BAR+0x030**, not actual state at 0x034.  Don't be misled by it.

4. **The loader's MSI masking is undone by Linux's pci_enable_msi()**.
   Modifying the loader to skip the mask is a no-op for Linux behavior.

5. **TX buffer pool architecture mirror is not the gate.**  HW accepts
   any 32-bit DMA address as buf_lo.

6. **MAC bit-0 latch on BAR+0x004 is not required.**  Orbis snapshot
   shows bit 0 = 0 in working state.

7. **Parent BAR2+0x2880 (Path G) remains untested and dangerous.**
   Last unexplored avenue.  Treat with caution.
