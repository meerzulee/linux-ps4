# hermes — v92 PHY TX failure Ghidra re-audit — 2026-05-13

Concrete finding: I do NOT see an Orbis function between `mts_attach` and link-up whose purpose is “turn on PHY TX output” or “enable RGMII TX_CLK output direction” as a late missing step. Orbis assumes the MT7531 PHY analog TX path is alive after reset/POR plus its normal `mts_mac_init` PHY tuning and BMCR AN restart. The only MAC-side clock-ish writes are the ones already known: parent prelude, `BAR+0x07c=25000000`, `BAR+0x078 &= ~1`, and `BAR+0x030=0x10100`. No separate “TX_CLK output enable” register surfaced in the audited MTS path.

## Audited path

Ghidra project: Orbis 12.02 kernel ELF.

Relevant functions checked:

- `mts_attach` `ffffffffc85ec030`
- `mts_ifup` `ffffffffc85ec940`
- `mts_mac_init` `ffffffffc85ecb60`
- `mts_intr` `ffffffffc85edcf0`
- `mts_init_rings_kick` `ffffffffc85ef1b0`
- `gbe:phy_ctrl` body `FUN_ffffffffc85f0480`
- `gbe:ctrl` body `FUN_ffffffffc85f0190`
- side functions in `ffffffffc85ec000..ffffffffc85f0fff`: `FUN_c85ec710`, `FUN_c85ecad0`, `FUN_c85ef020`, `FUN_c85ef7d0`, `FUN_c85f0910`, `FUN_c85f0e50`
- parent `baikal_gbe_attach` `ffffffffc8511100`
- parent `msk_init_hw` `ffffffffc8511d50`
- parent prelude `FUN_ffffffffc85131d0`
- parent PHY helpers `FUN_ffffffffc85133d0`, `FUN_ffffffffc85136e0`, `FUN_ffffffffc85138b0`, `FUN_ffffffffc8513a70`, `FUN_ffffffffc8513c60`

## MAC RGMII / TX_CLK enable audit

No explicit “RGMII TX_CLK direction/output enable” bit was found.

The only MTS MAC clock/routing-looking writes in Orbis `mts_mac_init` are:

- `BAR+0x07c = 25000000` at `mts_mac_init` decompile lines around the `+0x7c` store.
- `BAR+0x078 &= ~1` immediately before the final C45 tail.
- `BAR+0x030 = 0x10100` near the end of MAC register setup.
- `BAR+0x010 = (old & 0xffffff6e) | 0x81` before `BAR+0x030`.
- `BAR+0x008 |= 0x07597c00`, `BAR+0x00c &= ~0x80`, pause `BAR+0x074=0x2277`.

Parent/prelude clock-ish writes:

- `FUN_ffffffffc85131d0(param,1)` writes `BAR+0xf10=1`, `BAR+0xf10=2`, `BAR+0xf04=1`, delay, `BAR+0xf04=2`, then `BAR+0x120=1`, then `BAR+0x11c &= 0xf8ff`.
- `msk_init_hw` wraps that with `BAR+0x04=8`, earlier `BAR+0x158/0x160` masking/latching, and later `BAR+0x138=2` then `1`.

I found no Orbis write to a new BAR offset that looks like “drive TX clock out to PHY” after these. `gbe:ctrl` and `gbe:phy_ctrl` do not program MAC clock routing; they poll link and restart AN.

## PHY TX / analog output enable audit

There IS PHY analog programming in `mts_mac_init`, but it is not a late standalone TX-enable function. It happens inside the normal MAC init before link polling.

`mts_mac_init` does a large MMD 0x1e/0x1f sequence gated by an efuse/config condition (`FUN_ffffffffc8764760(0x6c)` bits). Notable writes:

- MMD 0x1e regs `0x0e`, `0x172..0x175`, `0x12`, `0x16..0x22`, `0x96`, `0x37`, `0x39`, `0x171`.
- MMD 0x1f reg `0x115`, `0x107`.

Then the unconditional tail writes:

- `mts_smi_cl45_write(param, 0x189001e, 0x110)`
- page `0x52b5` token-ring style writes:
  - reg11 `0xb90a`, reg12 `0x006f`, reg10 `0x8f82`
  - reg11 `0xbaef`, reg12 `0x002e`, reg10 `0x968c`
- page 3 reg `0x1c = 0x0c92`
- `BAR+0x07c = 25000000`
- `mts_smi_cl45_write(param, 0x122001e, 0xffff)`
- more page `0x52b5` token-ring writes:
  - `0x704d/0/0x9698`
  - `0x344f/2/0x969a`
  - `4/0/0x9686`
  - `0x0671/6/0x8fae`
- `mts_smi_cl45_write(param, 0x268001f, 0x07f4)`
- ANAR mask: C22 reg4 `&= 0xf3ff`
- `BAR+0x04 &= 0x7fffcfff`, `BAR+0x078 &= ~1`
- `mts_smi_cl45_write(param, 0x3c0007, 0)`
- MMD 0x1e reg `0x330 &= ~0x1000`
- BMCR read then `BMCR |= 0x1200` (AN enable + restart)

Brutal interpretation: if there is a PHY TX analog enable in Orbis, it is buried in this `mts_mac_init` MMD/TR blob, not in a separate `mts_phy_init`/`phy_power_up` function. There is no later “oh, enable transmitter now” call.

## `gbe:phy_ctrl` audit

`FUN_ffffffffc85f0480` does not enable TX. It:

- initializes event state to `0x100`;
- on event `0x100`, reads MMD 0x1e reg `0xa2` twice, then polls C22 BMSR reg1;
- if BMSR link never appears, toggles 1000BT advertise bit in C22 reg9 and restarts AN via BMCR `|=0x1200`;
- on event `1`, if MAC BAR+0x04 bit0 is down, ensures C22 reg9 bit `0x200` and C22 reg4 bits `0x180`, then BMCR `|=0x1200`.

No C45 analog TX path writes. No MAC BAR clock-routing writes except reading BAR+0x04.

## `msk_phy_power_up` / parent PHY helpers

I do not see a renamed `msk_phy_power_up`, but `FUN_ffffffffc85133d0` is the closest parent PHY power/config helper. It uses the parent MSK MDIO block at BAR+0x2880/0x2884 via `FUN_ffffffffc85136e0`/`FUN_ffffffffc85138b0`, not the MTS SMI engine at BAR+0x00. It checks a Marvell-ish PHY ID and writes C22 pages/registers like page `0xff`, `0xfb`, `0xfc`, page 3 reg `0x12`, then BMCR reset/restart patterns.

That looks like legacy Yukon/Marvell PHY setup, not MT7531 MTS SMI setup. I would not chase it as the missing Baikal MT7531 TX enable unless we have evidence BAR+0x2880 reaches the same PHY on this silicon. The MT7531 path in Orbis is the `mts_smi_*` path.

## Important Linux-side hazard found while checking source

Current `src/6.x-baikal/drivers/net/ethernet/sony/ps4_mts.c` appears to call `mts_phy_init()` after `mts_mac_init()` in probe. `mts_phy_init()` does:

- C22 BMCR `0x8000` soft reset;
- wait for reset clear;
- C22 BMCR `0x1200` AN restart.

Orbis does not do a full PHY soft reset after the big `mts_mac_init` MMD/TR programming; it only restarts AN (`BMCR |= 0x1200`) inside `mts_mac_init`, and later `gbe:phy_ctrl` restarts AN if needed. If Linux soft-resets after applying v87/v88/v89 MMD/TR/TX-delay writes, it may erase exactly the PHY analog/TX-delay state we think we applied. This is not a Ghidra “missing Orbis function”; it is a possible Linux ordering bug.

Before any new register roulette, read back after all Linux init is complete, immediately before/after AN:

- MMD 0x1e regs `0x13`, `0x14`, `0x330`, `0x123`, `0xa6`, `0xc6`
- MMD 0x1f reg `0x268`
- C22 page/TR SlvDPSready value
- C22 BMCR/BMSR/ANAR/1000BT_CTRL

If those reverted after `mts_phy_init()`, the v92 failure has a boring explanation: Linux is resetting away the PHY TX/analog setup.

## Answer to the v92 question

- MAC RGMII TX_CLK output direction/enable: no separate Orbis enable found. Best candidates are already-known `BAR+0x030=0x10100`, `BAR+0x07c=25000000`, `BAR+0x078 &= ~1`, parent `0x11c/0x120/0x138/0x158/0x160` setup.
- PHY TX driver / output power / analog TX enable: no separate function found. Orbis does PHY analog/TR programming inside `mts_mac_init`; after that it only restarts AN and polls/retries. If TX is off, either one of those `mts_mac_init` MMD/TR writes is missing/clobbered, or the PHY/board analog path is not being powered by a software-visible MTS routine.
- Most actionable next experiment: do not add new writes. First remove/skip the post-`mts_mac_init` Linux C22 soft reset, or move all PHY MMD/TR/TX-delay programming after it, and add readback proof that the final live PHY state still contains v87/v88/v89 writes.