# v110: Full gbe:ctrl thread analysis — TX deadlock root cause update

**Date**: 2026-05-13
**Agent**: glm-5.1
**Source**: Ghidra MCP decompilation of orbis-12.02.elf

## Summary

Full decompilation and analysis of the `gbe:ctrl` kernel thread
(FUN_ffffffffc85f1e80), `mts_init_rings_kick` (FUN_ffffffffc85ef1b0),
`mts_ifup` (FUN_ffffffffc85ec940), and `mts_mac_init`
(FUN_ffffffffc85ecb60). Key findings:

1. **ALL mts_mac_init BAR writes are already present in our Linux driver**
   (lines 489-523 of ps4_mts.c). No missing init registers.

2. **The `BAR+0x1c8` "rings-ready" semaphore is kernel memory, NOT MMIO**.
   Our v110 write `(orig & ~0x440) | 0x40` to BAR+0x1c8 targets the wrong
   address. In Orbis, the bit-6 check and set is on `parent_struct+0x1c8`
   (kernel heap), not BAR+0x1c8. The v110 write is harmless but ineffective.

3. **gbe:ctrl adds only ONE BAR write after link UP: `BAR+0x54 &= ~0x1000`**
   (clear bit 12 of IRQ mask). Our mask value 0x007bbffe includes bit 12,
   and Orbis clears it after link UP.

4. **TX remains blocked by BAR+0x04 bit 0 not latching** → BAR+0x06c bit 9
   (TX DMA ready) never sets → descriptors never processed.

## gbe:ctrl (FUN_ffffffffc85f1e80) full sequence

```
1. mts_init_rings_kick(parent_device)
      - Sets up TX/RX descriptor rings in BAR+0x3c/0x40/0x44/0x48
      - BAR+0x34 |= 1 (TX DMA engine start)
      - BAR+0x38 |= 1 (RX DMA engine start)
      - BAR+0x54 = softc+0x3098 (irq mask value)
      - parent_struct+0x1c8 = (orig & 0xfffffbbf) | 0x40  // KERNEL MEMORY!

2. If (param_1+0x30dc != 0):  // switch mode
      parent_struct+0x80 |= 1                 // KERNEL MEMORY flag, not BAR+0x80!
      ioctl_handler(0x80206910)

3. If (param_1+0x30e0 != 0):  // need to wait for link
      Loop up to 0x46 (70) iterations:
            Read BAR+0x04, check bit 0 (link UP)
            If bit 0 set:
                  Send mgmt frame (tag 0xfa42, type 0x800b)
                  Call FUN_ffffffffc85f2250(parent_device)
                  Break
            mdelay(1s equivalent)

4. After link UP (or no wait needed):
      parent_struct+0x3099 byte &= 0xef       // clear bit 4 (KERNEL MEMORY)
      BAR+0x54 &= ~0x1000                     // ← ONLY NEW BAR WRITE
```

### FUN_ffffffffc85f2250 (post-link-UP mgmt frame burst)

```
1. MDIO read ports 2,3,4 reg 0x13 (extended status)
2. Send mgmt frame (type 0x800b) — port/vid config
3. Send mgmt frame (type 0x600b) — IGMP config
4. If response bit 0 set: "L2 switch has been reset" log
5. Call FUN_ffffffffc85f1010 (read PHY stats, notify OS)
```

### FUN_ffffffffc85f1010 (PHY link status to OS notification)

Reads PHY registers on ports 2,3,4 via MDIO (reg 0x11, extended status).
Decodes speed/duplex/pause and calls `if_link_state_change()`.

## mts_init_rings_kick (FUN_ffffffffc85ef1b0) complete BAR writes

| BAR offset | Value/Operation | Meaning |
|-----------|-----------------|---------|
| 0x44 | softc+0x40 | TX desc address (hi or same as lo for <4GB) |
| 0x3c | softc+0x40 | TX desc address |
| 0x48 | softc+0x50 | RX desc address (hi or same as lo for <4GB) |
| 0x40 | softc+0x50 | RX desc address |
| 0x34 | val \|= 1 | TX DMA engine start |
| 0x38 | val \|= 1 | RX DMA engine start |
| 0x54 | softc+0x3098 | IRQ mask |

**Critical**: The `parent_struct+0x1c8` check/set at entry/exit is a
kernel-internal "already initialized" guard. NOT the same as BAR+0x1c8
(MTS_MCAST_MASK). Our v110 code writes BAR+0x1c8 with the rings-kick
pattern, which is wrong target but harmless.

## mts_ifup (FUN_ffffffffc85ec940) sequence

```
1. Set softc+0x32b0 = 0xa000000000000  (timeout?)
2. Call mts_mac_init(softc)
3. **parent_struct+0x1c8 &= ~0x40**   // KERNEL MEMORY — clear "rings kicked" flag
4. Call mts_init_rings_kick(parent_device)
5. kthread_resume(gbe:ctrl)
6. If (softc+0x30e0 == 0): kthread_resume(gbe:phy_ctrl)
7. sx_xlock(sleepable lock) on softc+0x3178 and softc+0x31c8
```

### Parent struct 0x1c8 bit 6 is NOT BAR+0x1c8

- `parent_struct+0x1c8` is accessed via `*(*(softc + 0x30a0)) + 0x1c8`
  This walks: softc → device_ptr → first_field → offset 0x1c8
  The result is in KERNEL MEMORY (heap), not MMIO BAR space.

- The `mts_ifup` clear (`&= ~0x40`) and `mts_init_rings_kick` set
  (`(& 0xfffffbbf) | 0x40`) form an init guard: if bit 6 is already
  set, rings_kick returns immediately.

- Our v110 write to BAR+0x1c8 with this pattern is targeting the wrong
  register. The actual BAR+0x1c8 writes from mts_mac_init are:
  - DA filter entries (0x1bc/0x1c0/0x1c4) — gated by switch config
  - Final: BAR+0x1c8 |= 0xc0000000 (accept-all) — also gated

## mts_mac_init (FUN_ffffffffc85ecb60) — All writes VERIFIED in our driver

| BAR offset | Value | Our #define | Present in driver? |
|-----------|-------|-------------|---------------------|
| 0x200 | 0 | — | ✓ (disable master IRQ) |
| 0x50 | W1C readback | MTS_IRQ_STATUS | ✓ |
| 0xAC | 9 | MTS_INIT_AC | ✓ |
| 0x7C | 25000000 | MTS_MAC_CLK | ✓ |
| 0x04 | val & 0x7fffcfff | — | ✓ (clear bits 16,20-23) |
| 0x78 | val & ~1 | MTS_RX_GATE | ✓ |
| 0x14 | MAC addr byte-swapped | MTS_MAC_ADDR0_HI | ✓ |
| 0x18 | MAC addr swapped | MTS_MAC_ADDR0_LO | ✓ |
| 0x140-0x144 | MAC + 0x80000000 | (switch mode only) | ✓ (conditional) |
| 0x0C | val & ~0x80 | MTS_MAC_CTRL2 | ✓ |
| 0x74 | 0x2277 | MTS_MAC_PAUSE | ✓ |
| 0x08 | val \|= 0x07597c00 | MTS_MAC_CTRL1_INIT_OR | ✓ |
| 0x1D4 | 1 | MTS_INIT_1D4 | ✓ |
| 0x10 | (val & 0xffffff6e) \| 0x81 | MTS_MAC_CTRL3 | ✓ |
| 0x30 | 0x10100 | MTS_MAC_MODE | ✓ |
| 0x1c8 DA | entries | MTS_MCAST_* | ✗ (switch-gated, skipped) |
| 0x1c8 | \|= 0xc0000000 | — | ✗ (switch-gated, skipped) |

**ALL unconditional writes from mts_mac_init are present in our driver.**

## mts_link_change (FUN_ffffffffc85eeb90)

Reads BAR+0x04 and decodes:
- Bit 0: link UP
- Bits 2-3: speed (0=10M, 1=100M, 2=1G)
- Bit 4: full duplex
- Bit 6: pause
- Bit 8: asym pause

Then calls `if_link_state_change()` with the decoded media status.

**Nothing new here** — our phy_ctrl kthread does similar link monitoring.

## FUN_ffffffffc85f0910 (MT7531 switch reinit)

This function manipulates BAR+0x10 and BAR+0x1c (MII management register):
- If parent_struct+0x80 & 0x100 (SGMII/SWITCH mode):
  - BAR+0x10 |= 0x10 (set bit 4 — MAC MII management enable?)
- If NOT switch mode:
  - If BAR+0x10 bit 4 set, clear it
  - Write 0x80000000 to BAR+0x1c (start MII read command)
  - Wait for BAR+0x1c bit 17 (0x20000) — MII complete
  - Do PHY enumeration via MII/CRC
  - Or write 0x7000+i to BAR+0x1c 256 times (PHY register dump)

BAR+0x1c is the MII MDIO command/data register — this is for PHY management
via the MAC's built-in SMI interface, not the same as the MT7531 SMI
(based on BAR+0x00, 0x02) that our driver uses.

## Root cause remains: BAR+0x04 bit 0 won't latch

Despite having all the right init writes, our driver cannot get TX working
because:

1. **BAR+0x04 bit 0** (link status latch) never transitions to 1
2. **BAR+0x06c bit 9** (TX DMA ready) depends on bit 0 being 1
3. Without TX DMA ready, the TX engine never fetches descriptors
4. TX is 100% dead despite correct descriptor setup

## New finding: BAR+0x54 bit 12

gbe:ctrl clears bit 12 of BAR+0x54 after link UP detection.
Our mask (0x007bbffe) includes bit 12, and we never clear it.
This might cause an interrupt-related issue but is unlikely to
be the root cause of TX dead.

## What's different between Orbis and our driver (delta)

| Item | Orbis | Our driver | Impact |
|------|-------|------------|--------|
| parent_struct+0x1c8 &= ~0x40 | kernel flag clear | NOT DONE | Likely irrelevant — kernel memory |
| parent_struct+0x1c8 &= ~0x440 \| 0x40 | kernel flag set | BAR+0x1c8 write instead | Wrong target, harmless |
| BAR+0x54 &= ~0x1000 | After link UP, clear bit 12 | NOT DONE | Minor — IRQ mask |
| gbe:ctrl thread | Polls BAR+0x04 for link, sends mgmt frames | phy_ctrl kthread polls PHY via MDIO | Different approach |
| mgmt frame 0x800b/0x600b | Sent via ICC/switch CPU | NOT DONE | Switch-specific, NA for us |
| BAR+0x1c8 \|= 0xc0000000 | DA filter accept-all (switch-gated) | NOT DONE | Might matter if MAC filters TX |
| BAR+0x80 \|1 in gbe:ctrl | parent_struct kernel flag | NOT DONE | Kernel memory, N/A |

## Next actions

1. **Get Orbis BAR0 dump** via the dumper payload (softc→resource+0x10→KVA walk)
   — This will show the exact register state of a WORKING PS4 and we can
   diff byte-by-byte against our v97 state.

2. **Try BAR+0x1c8 |= 0xc0000000** (accept-all multicast/broadcast)
   — Even though the DA filter loop is switch-gated, the accept-all bits
   might be needed for TX to work. Without them, the MAC might reject
   all outgoing frames.

3. **Try BAR+0x54 &= ~0x1000** after link UP
   — Clear bit 12 of IRQ mask, matching Orbis gbe:ctrl behavior.

4. **Verify parent_struct+0x1c8 is kernel memory** by checking Ghidra
   for what struct/device the softc+0x30a0 pointer resolves to.