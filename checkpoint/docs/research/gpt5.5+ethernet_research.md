# gpt-5.5 — 2026-05-12

Concrete finding: `msk_init_hw` does not contain a hidden BAR+0x180..0x1d4 MAC/SMI programming sequence that Linux sky2_reset simply forgot. In the BAR+0x100..0x1d4 window, the Orbis parent mostly touches the same Yukon-ish reset/status-control registers Linux already touches, plus one Sony-specific prelude helper (`FUN_c85131d0`) that Linux only partially mirrors. The later destructive-looking BAR+0x180..0x1d4 collisions are from Linux `sky2_mac_init()` / open path, not from `sky2_reset()` vs Orbis `msk_init_hw()`.

## Evidence from Ghidra MCP

Primary Ghidra anchors:
- `msk_init_hw` = `0xffffffffc8511d50`
- helper called early by `msk_init_hw`: `FUN_ffffffffc85131d0`
- Linux comparison: `src/6.x-baikal/drivers/net/ethernet/marvell/sky2.c:3381+` (`sky2_reset`), `sky2.c:994+` (`sky2_mac_init`)

### BAR+0x158 / BAR+0x160: Orbis and Linux mostly agree

At the top of `msk_init_hw` (`0xffffffffc8511d50`), Orbis conditionally reads BAR+0x158 and BAR+0x160 when `FUN_c8572d60() == 0x10300`:

- If `FUN_c85b21d0() - 1 < 4`:
  - `BAR+0x158 &= 0xcccccccc`
  - `BAR+0x160 &= 0xf33fffff`
- Else if `FUN_c85b21d0() == 0`:
  - `BAR+0x158 &= 0xfffffccc`

Linux's PS4 sky2_reset block at `sky2.c:3388-3405` does exactly the first branch unconditionally for Sony GBE:

- writes BAR+0x60/0x64/0x68/0x6c
- `val1 = read32(0x158); val1 &= ~0x33333333` == `& 0xcccccccc`
- `val2 = read32(0x160); val2 &= ~0x0cc00000` == `& 0xf33fffff`

So if the PS4 Pro Baikal path is the `FUN_c85b21d0()-1 < 4` case, Linux already matches. If hardware is actually in the `==0` case, Linux is missing the stronger `0x158 &= 0xfffffccc` mask. That is one uncertainty worth logging, but not enough to explain the one-way SMI death after open.

### Missing subtlety: Orbis drives BAR+0x158 through mode 2 then mode 1

After the initial mask, Orbis does two explicit low-bit transitions on BAR+0x158 inside `msk_init_hw`:

- early: `BAR+0x158 = (old & 0xfffffffc) | 2`
- later: `BAR+0x158 = (old & 0xfffffffc) | 1`

Linux sky2_reset only masks 0x158/0x160; I did not find the same `2 -> 1` sequencing in the PS4-specific block. If BAR+0x158 is a test/config latch or clock-domain selector, the sequence may matter more than the final visible value. This is a stronger candidate than “restore final BAR state” because v80/v81 showed final BAR-visible state can look good while SMI stays dead.

### `FUN_c85131d0(param_1, 1)` is the main Orbis parent prelude Linux does not fully model

`msk_init_hw` calls `FUN_c85131d0(param_1, 1)` immediately after writing BAR+0x04=8. That helper does:

- `BAR+0xf10 = 1`, then `BAR+0xf10 = 2`
- `BAR+0xf04 = 1`, delay 12 ms, then `BAR+0xf04 = 2`
- if chip id byte at softc+0x30 is `0xbd`, writes the familiar Baikal values:
  - `BAR+0x60 = 0x32100`
  - `BAR+0x64 = 6`
  - `BAR+0x68 = 0x63b9c`
  - `BAR+0x6c = 0x300`
  - otherwise only `BAR+0x64 = 0x4000006`
- `BAR+0x120 = 1`
- `BAR+0x11c &= 0xf8ff`

Linux sky2_reset has the 0x60..0x6c Baikal constants, but I do not see the surrounding Orbis reset choreography around 0xf10/0xf04/0x120/0x11c in the same order. This may be a parent-level “switch/GPHY/MAC glue reset” sequence, not an MTS child sequence. It happens before Orbis allocates/attaches the `PORT_A` child and before `mts_attach`/`mts_mac_init`.

### BAR+0x138: Orbis and Linux again agree

Orbis writes BAR+0x138 = 2 then BAR+0x138 = 1. Linux sky2_reset writes `B2_TI_CTRL` at BAR+0x138 with `TIM_STOP` then `TIM_CLR_IRQ` (`sky2.c:3534-3536`). This is probably not the missing MDC-enable bit.

### BAR+0x180..0x1d4: parent `msk_init_hw` is not the source

I found no direct Orbis parent `msk_init_hw` writes to BAR+0x180..0x1d4. The 0x1bc..0x1d4 multicast/hash programming is in `mts_mac_init` (`0xffffffffc85ecb60`), not `msk_init_hw`. Linux `sky2_mac_init` starts doing GMAC writes through `gma_write16()` after `sky2.c:1031`; with Yukon port base this lands in exactly the suspicious Baikal region:

- `GM_TX_CTRL` / `GM_RX_CTRL` / `GM_TX_FLOW_CTRL` / `GM_TX_PARAM` / `GM_SERIAL_MODE`
- source address registers
- MIB clear via `GM_PHY_ADDR`

This supports the v81 conclusion: the likely MDC killer is not `B0_IMSK` and probably not `sky2_reset`; it is `sky2_mac_init()` or later open-path writes landing on Sony-specific MAC config space.

## Disagreement / refinement vs current notes

I agree with v81/v82 that sky2-as-shell is becoming whack-a-mole. But I would refine Q4 this way: do not look for a missing 0x180..0x1d4 block in `msk_init_hw`; it is not there. If continuing sky2, the immediate suspect is `sky2_mac_init` writes into 0x180+ while Orbis parent never does that. If pivoting to standalone `ps4_mts.c`, include the parent prelude (`FUN_c85131d0(1)` plus 0x158 mode sequencing) before `mts_mac_init`, not just the child `mts_mac_init` register list.

Recommended next experiment on hardware: in standalone `ps4_mts.c`, before `mts_mac_init`, replay the Orbis parent prelude in order (`0xf10 1->2`, `0xf04 1 delay 12ms ->2`, `0x60/64/68/6c`, `0x120=1`, `0x11c&=0xf8ff`, `0x158 mode 2->1`), logging raw BAR+0 and BMSR after each group to identify the first transition that enables or kills MDC.
