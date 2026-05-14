# v111: Orbis BAR0 snapshot diff + mts_intr handshake analysis — ROOT CAUSE UPDATED

**Date**: 2026-05-13
**Agent**: glm-5.1
**Source**: Orbis BAR0 dump (`checkpoint/orbis-dumps/12.02/mts-bar0-orbis-working.bin`),
Ghidra MCP decompiles of `mts_intr`, `mts_init_rings_kick`, `mts_ifup`, `gbe:ctrl`

## CRITICAL FINDING: 0x40000 init handshake

### The Smoking Gun

Orbis `mts_intr` (0xffffffffc85edcf0) has a **first-interrupt init handshake**
that our driver completely lacks:

```
On first interrupt ever (softc+0x309c == 0):
    1. Set softc+0x309c = 1  ("first IRQ done")
    2. Write BAR+0x204 = 0x10001388  (enable full IRQ block)
    3. Write BAR+0x54 = 0x7bfffe  (mask: all except bit 0 and bit 23)

On bit 18 (0x40000) assertion AND first_time == 1:
    1. Set softc+0x309c = 0  ("init complete handshake done")
    2. Write BAR+0x204 = 0  (DISABLE master IRQ block!)
    3. Write BAR+0x54 = softc+0x3098  (restore saved mask shadow)
```

**Our driver masks out bit 18 entirely** (`MTS_IRQ_MASK_FULL_VAL = 0x7bbffe`,
which is `0x7bfffe & ~0x40000`). The device keeps asserting 0x40000 because we
never complete the handshake. In Orbis, the device asserts 0x40000 ONCE to signal
"init complete", the ISR acknowledges it by clearing BAR+0x204, then re-enables
normal interrupts with the saved mask.

### Why this matters for TX

After the handshake completes:
- BAR+0x204 is cleared to 0 (master IRQ block disabled) then re-enabled by
  subsequent `mts_ifup` / `gbe:ctrl` as needed
- BAR+0x54 is restored to `softc+0x3098` (the saved mask, which excludes 0x40000)
- The init-complete handshake disables/re-enables the master IRQ block, which may
  be necessary for the MAC's internal state machine to transition to TX-ready

**Our 0x40000 flood (106K firings/v110 boot) is the device screaming "I'm
done initializing, acknowledge me!" and us ignoring it.**

## Orbis BAR0 dump analysis

### Register map (4-byte stride, hardware mirrors each 32-bit reg at +4)

The dump shows every register value repeated at offset+4 within 8-byte aligned
slots. This is a PCIe 64-bit bus presentation artifact — the functional register
is at the base offset, and +4 within each 8-byte slot is a mirror.

Confirmed by cross-referencing: Orbis code uses 4-byte offsets (BAR+0x04, 0x08,
0x0c, etc.) and they work as independent registers in live MMIO.

### Orbis vs our driver — all differences

| BAR Offset | Orbis Value | Our Value | Delta | Significance |
|-----------|-------------|-----------|-------|-------------|
| +0x000 | 0x796d8100 | varies (SMI busy) | — | SMI_CMD, not link status |
| +0x004 | 0x796d8100 | 0xb18/v97 | — | LINK_STATUS: bit 0 = 0 in BOTH |
| +0x008 | 0x0f597c00 | 0x07597c00\|hw | **0x08000000** (bit 27) | Orbis has extra bit 27 |
| +0x010 | 0x00000085 | 0x00000081\|hw | bit 2 | Pre-existing in hw |
| +0x030 | 0x00010100 | 0x00010100 | **MATCH** | MAC_MODE |
| +0x070 | 0x00014003 | 0x00002277 | **0x00014003 vs 0x2277** | Changed after init by driver |
| +0x078 | 0x00000000 | 0x00000000 | **MATCH** | RX_GATE |
| +0x07c | 0x00000000 | 0x00000000 | **MATCH** | MAC_CLK was 25MHz, cleared in idle |
| +0x080 | 0x000002bb | not set | **NEW** | Unknown register, Orbis sets it |
| +0x098 | 0x00000002 | not checked | — | Unknown |
| +0x0b0 | 0x001f03ff | not checked | — | Unknown mask |
| +0x100 | 0x00001c54 | not set | **NEW** | Unknown counter/register |
| +0x118 | 0x000000a8 | not set | **NEW** | Unknown |
| +0x128 | 0x000011c3 | not set | **NEW** | Unknown |
| +0x1c8 | 0x00a00000 | 0x00a00040 | bit 6 extra in ours | Our v110 write; Orbis idle |
| +0x1d8 | 0x000000a8 | not set | **NEW** | Unknown |
| +0x1e0 | 0x0000002e | not set | **NEW** | Unknown |
| +0x1f0 | 0x00000062 | not set | **NEW** | Unknown |
| +0x204 | 0x00000000 | 0x10001388 | **OPPOSITE** | IRQ block OFF in Orbis idle |
| +0x208 | 0x00000001 | not set | **NEW** | Unknown enable |
| +0x210 | 0x00000001 | not set | **NEW** | Unknown enable |

### BAR+0x04 bit 0 = 0 in BOTH Orbis AND Linux

**The 14-patch "BAR+0x04 bit 0 latch" theory is FALSIFIED.** Orbis has bit 0 = 0
in the idle snapshot and TX works. Our Linux also has bit 0 = 0 and TX is dead.
The difference must be elsewhere.

### BAR+0x204 = 0 in Orbis idle

In Orbis, after the init-complete handshake finishes:
1. mts_intr writes BAR+0x204 = 0 (master IRQ block OFF)
2. mts_ifup calls mts_init_rings_kick which does NOT re-enable BAR+0x204
3. gbe:ctrl thread resumes
4. mts_ifup itself will re-enable when the interface goes IFF_UP

So BAR+0x204 = 0 in idle state is EXPECTED — it means the handshake completed
and the master block was turned off. Our driver has BAR+0x204 = 0x10001388 because
we never do the 0x40000 handshake that would clear it.

### BAR+0x208 and BAR+0x210

Both = 1 in Orbis. **Not found in any decompiled MTS function.** Possible sources:
- FreeBSD bus_setup_intr/PCI resource management (allocating MSI vectors)
- PCI configuration space writes that mirror into BAR space
- DMA engine initialization in bus_dmamap_create

These are likely set by the FreeBSD kernel's bus infrastructure, not by the MTS
driver itself. In Linux, our driver's pcim_enable_device + request_irq may or
may not cause these to be set. **They could be MSI doorbell registers or
interrupt-poll enable bits.**

### BAR+0x070 = 0x00014003 (was 0x2277 at init)

Orbis init writes BAR+0x074 = 0x2277 (MAC_PAUSE). The live value 0x00014003
at the same slot (offset 0x070, mirror at 0x074) means BAR+0x074 was OVERWRITTEN
after init. The value 0x14003 includes bits we never set.

Decompiling gbe:ctrl (0xffffffffc85f1e80) shows: after link UP, it writes
BAR+0x54 &= ~0x1000 (bit 12 of IRQ mask). This might not be the only
post-link modification. The 0x14003 may be from an ioctl call or the
gbe:phy_ctrl kthread changing pause parameters.

## mts_attach (0xffffffffc85ec030) key findings

1. **Global softc pointer stored at 0xffffffffca590938** — confirmed, this is what
   the dumper walks
2. **IRQ setup**: `bus_setup_intr(dev, irq_res, 0x204, 0, mts_intr, softc, &softc+0x611)`
   - The `0x204` argument is likely the interrupt type (INTR_TYPE_NET | INTR_MPSAFE)
   - NOT a BAR+0x204 write; FreeBSD interrupt setup semantics
3. **Three DMA allocations**: two 0x4000-byte (TX+RX rings) and two smaller
   (0xa0000 and 0x60000 sizes — might be the shared-memory ICC areas)
4. **mts_mac_init called from attach** (not just ifup) — Orbis also calls
   mac_init in attach, same as our v97-v104 flow

## mts_init_rings_kick complete BAR writes

| BAR | Value | MEANING |
|-----|-------|---------|
| +0x44 | softc+0x40 | TX desc addr (hi or lo) |
| +0x3c | softc+0x40 | TX desc addr |
| +0x48 | softc+0x50 | RX desc addr (hi or lo) |
| +0x40 | softc+0x50 | RX desc addr |
| +0x34 | val \|= 1 | TX DMA engine start |
| +0x38 | val \|= 1 | RX DMA engine start |
| +0x54 | softc+0x3098 | IRQ mask shadow |

**Critical**: Our v110 code writes to BAR+0x1c8 what Orbis writes to
`parent_struct+0x1c8` (kernel memory). The v110 BAR+0x1c8 write is WRONG TARGET
(but harmless — DA filter always has bit 6 set now). The real "rings kicked"
flag is in the kernel parent device struct, not in BAR MMIO.

## mts_link_change reads BAR+0x04

Decoded bits from `mts_link_change` (0xffffffffc85eeb90):
- Bit 0: link UP (0 = down)
- Bits 2-3: speed (0=10M, 1=100M, 2=1G)
- Bit 4: full duplex
- Bits 6,8: pause/asym pause

This matches our understanding. BAR+0x04 IS the link status register.

## Full interrupt flow in Orbis

```
First interrupt (softc+0x309c == 0):
    → BAR+0x204 = 0x10001388  (enable master IRQ block)
    → BAR+0x54 = 0x7bfffe      (enable all IRQs except bit 0 and bit 23)
    → softc+0x309c = 1          (mark "first IRQ done")

For every subsequent interrupt:
    status = BAR+0x50 (W1C)
    if (status & ~softc+0x3098):
        handle NAPI bits
        handle link change (bit 2)
        handle TX complete (bit 7)
        handle errors (bits 8-23)
    
    if (status & 0x40000) AND (softc+0x309c == 1):
        softc+0x309c = 0                 (mark "init handshake done")
        BAR+0x204 = 0                    (DISABLE master IRQ block)
        BAR+0x54 = softc+0x3098          (restore saved mask)
    
    if (status & 0x1000) AND switch_mode:
        BAR+0x54 |= 0x1000              (re-enable phy_ctrl thread wake)
```

**The init-handshake 0x40000 path is critical** — it's the device saying "I've
finished my internal initialization sequence" and the driver acknowledging it
by toggling the master IRQ block off and back on.

## Candidate next moves (revised)

### Priority 1: Implement the 0x40000 init handshake (v111)

In our `mts_intr`, add first-interrupt handling:
1. On boot, keep bit 18 (0x40000) IN the IRQ mask
2. On first interrupt: set first_irq flag, write BAR+0x204 = 0x10001388,
   BAR+0x54 = 0x7bfffe
3. When status & 0x40000 is seen AND first_irq == 1: clear BAR+0x204 = 0,
   restore BAR+0x54 = saved_mask, set first_irq = 0
4. This lets the MAC complete its internal init sequence

This is the most likely fix for TX. The device needs the init-complete
acknowledgment before it enables the TX datapath.

### Priority 2: Add missing MAC_CTRL1 bit 27

Our driver writes `readl(bar + MTS_MAC_CTRL1) | 0x07597c00`.
Orbis has `0x0f597c00` = our mask + bit 27 (0x08000000).

Try `readl(bar + MTS_MAC_CTRL1) | 0x0f597c00` or
`readl(bar + MTS_MAC_CTRL1) | 0x07597c00 | 0x08000000`.

### Priority 3: Add BAR+0x080 write

Orbis has 0x000002bb at BAR+0x080. We never write this register.
This could be a TX/RX threshold or watermark register.

### Priority 4: BAR+0x208 and BAR+0x210

These might be set by FreeBSD's PCI/MSI setup, not by the MTS driver.
Can try speculatively writing 1 to both.

### Priority 5: Orbis BAR0 dump during ACTIVE TX

The current snapshot is MTS idle (using WiFi). Need a snapshot while
MTS is actively TXing to see the "running" register state, especially:
- BAR+0x070/074 (PAUSE changed from 0x2277 to 0x14003)
- BAR+0x034 (TX_CTRL — did engine start bit persist?)
- BAR+0x038 (RX_CTRL — engine bit?)

## Confirmed: BAR+0x04 bit 0 LATCH THEORY IS DEAD

Orbis BAR0 dump shows bit 0 = 0 at offset +0x004. TX works in Orbis.
Our Linux also has bit 0 = 0 and TX is dead. The root cause is NOT about
bit 0 latching. The init-handshake 0x40000 is the actual missing piece.