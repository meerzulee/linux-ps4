# v106: Why Orbis-structure init-in-open still failed — missing BAR+0x1c8 clear

## Q1: The step we missed

Decompiling `mts_ifup` (0xffffffffc85ec940) reveals the EXACT sequence:

```c
mts_mac_init(lVar4);
puVar1 = (uint *)(**(long **)(lVar4 + 0x30a0) + 0x1c8);
*puVar1 = *puVar1 & 0xffffffbf;   // BAR+0x1c8 &= ~0x40 — CLEAR BIT 6
mts_init_rings_kick(*(undefined8 *)(lVar4 + 0x30a0));
```

**We never clear bit 6 of BAR+0x1c8.** This write happens BETWEEN `mts_mac_init` and `mts_init_rings_kick` in the Orbis open path. It was documented in v90 as "OR 0xc0000000" (which is what mts_mac_init does to 0x1c8 during the DA filter loop), but the CRITICAL step is the bit-6 CLEAR that mts_ifup does AFTER mac_init, before rings_kick.

BAR+0x1c8 is the hash/DA filter mask register. In the mts_mac_init DA-filter loop, 0x1c8 gets OR'd with 0xc0000000 (bits 30+31 set). Then mts_ifup clears bit 6. In sky2 terms, this is analogous to the TX_GMF_CTRL_T clear-reset-then-enable sequence — bit 6 likely gates the MAC's "accept all" or "forward-to-host" path. Without clearing it, the MAC may receive frames but never signal "link up" to the internal datapath.

This is corroborated by v90's table showing BAR+0x1c4 = 1/0 toggling and BAR+0x1c8 = OR 0xc0000000 from mts_mac_init. The mts_ifup clear of bit 6 is an additional step we never replicated.

## The full Orbis open sequence (in order)

1. `mts_mac_init()` — MAC reset, CTRL1-3, MODE, PAUSE, RX_GATE, CLK, INIT_AC, DA filter loop (0x1c4/0x1c0/0x1c8/0x1d0), IRQ block
2. **BAR+0x1c8 &= ~0x40** — clear DA filter bit 6 (THE MISSING STEP)
3. `mts_init_rings_kick()` — program TX/RX descriptor addresses, enable engines
4. kthread_resume(gbe:ctrl) — wake the link-monitoring thread
5. `0x3178 = 0x10000` — ctrl thread event flags
6. If switch port configured: kthread_resume(gbe:phy_ctrl), `0x31c8 = 0x10100`

## Why v105 still failed

v105 moved init to ndo_open but still did NOT clear bit 6 of BAR+0x1c8. The MAC init ran, PHY linked, but the post-init DA filter gate stayed set, preventing the MAC's link-status latch from evaluating the PHY's link signal into bit 0.

## Fix for v106

Add TWO lines right after `mts_mac_init(mts)` and before ring DMA writes:

```c
/* v106: Orbis mts_ifup clears bit 6 of the DA filter mask register
 * between mac_init and init_rings_kick.  Without this clear, the
 * MAC's link-status latch does not evaluate PHY link into bit 0. */
writel(readl(mts->bar + MTS_MCAST_MASK) & ~0x40u,
       mts->bar + MTS_MCAST_MASK);
```

## Q2: If v106 also fails — verdict

If clearing BAR+0x1c8 bit 6 also doesn't fire the latch, we're out of Orbis-mirroring options. The remaining untried paths would be:

1. **Full msk_init_hw replay** — all the 0xe8x/0xf0x writes we never did. Risk: v90 proved a full replay "destroys the MAC" but that may have been because mts_mac_init ran FIRST and set up state that the 0xe80 reset sequence wiped. With the new init-in-open order, running msk_init_hw BEFORE mts_mac_init might work.

2. **Status ring DMA setup** — BAR+0xe80/0xe84/0xe88/0xe8c with a proper status buffer address. On Baikal these reads return 0, but we never proved writes stick (v99 was never tested live, only later live test showed they don't — reads return 0). If the status unit truly doesn't exist, this is a dead end.

3. **BAR+0x074 = 0x2277** (TX watermark) from mts_mac_init — not yet tested.

If v106 fails, I recommend shipping half-duplex (RX-only) as a documented milestone. RX works perfectly; TX dead is a single register-gate problem that may require hardware documentation Sony hasn't published. The driver is useful for packet capture, DHCP, SSH inbound — real value even without TX.