# v107: BAR+0x1c8 DA filter loop — why bits 30+31 are absent and what to try

## Q1: Why Orbis has 0xc0a00000 but we have 0x00a00000

Decompiling `mts_mac_init` reveals the DA filter loop is **gated by a VLAN/switch flag**:

```c
iVar5 = *(int *)(param_1 + 0x314c);   // switch config flag
// ...
*puVar9 = 0x10100;                     // BAR+0x030 = 0x10100
if (iVar5 == 0) goto LAB_ffffffffc85edc99;  // SKIP entire DA filter if no switch
```

The DA filter body (BAR+0x1bc data, 0x1c0 index, 0x1c4 strobe, 0x1d0 poll) only runs when the switch is configured. After the loop, it writes:

```c
BAR+0x1c4 = 3;                        // filter done
BAR+0x1c8 |= 0xc0000000;              // SET bits 30+31 (accept-all masks)
```

On Baikal we have no switch config (`param_1 + 0x314c == 0`), so the entire DA filter section is skipped. **Bits 30+31 of BAR+0x1c8 are never set** — that's why we read 0x00a00000 instead of 0xc0a00000.

Bit 30 likely = "accept all unicast" (DA filter pass-all). Bit 31 likely = "accept all multicast/broadcast". Without them, the MAC's internal frame-accept datapath is gated, which could include the link-status evaluation path.

The mts_mac_init code that we DO run also writes to BAR+0x1c8 — but only the length/OR portion:

```c
uVar6 = (int)uVar11 + 0x20;          // vlan tag length
BAR+0x1c8 |= (uVar6 * 0x100 | uVar6); // sets lower 16 bits
```

This accounts for the 0x00a00000 we see (the a0 in the low bits), but NOT the 0xc0000000.

**We also miss BAR+0x030 = 0x10100** which is written just before the DA filter gate check. This is the TX/RX frame size config register identified in v100.

## Q2: Is this a rising-edge toggle on bits 30+31?

No. The sequence is:
1. DA filter loop ORs length info into BAR+0x1c8 (low bits)
2. DA filter loop writes MAC addresses (unicast, multicast)
3. `BAR+0x1c8 |= 0xc0000000` (one-shot enable of accept-all masks)
4. `mts_ifup`: `BAR+0x1c8 &= ~0x40` (clear bit 6)

We never reach step 3. There's no toggle — bits 30+31 are simply never enabled. The latch failure is likely because the MAC's internal accept path (controlled by these bits) is required for link-status evaluation, not because of a rising edge.

## Q3: What to try

Write `0xc0a00000` to BAR+0x1c8 directly (OR our current value with 0xc0000000). This should set the accept-all-unicast and accept-all-multicast mask bits that the DA filter loop normally sets. If the latch fires, we know the root cause.

Also write BAR+0x030 = 0x10100 (frame config) which we've never done — this is another mts_mac_init write that's skipped because it's inside the same `if (iVar5 != 0)` guard after the MAC address setup.

Order for the test (bar_poke.py or ndo_open patch):

```
# Must be done AFTER mts_mac_init but BEFORE engine start
bar_poke 0x1c8 0xc0a00000    # set bits 30+31 (accept-all masks)
bar_poke 0x030 0x10100       # TX/RX frame config (73-bit VLAN tag)
```

Then check `bar_poke 0x004` — if bit 0 latches, the DA filter mask bits were the gate all along.