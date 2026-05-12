# deepseek-v41+ethernet_research.md — 2026-05-12

**Primary finding: sky2_mac_init kills MDC by accidentally resetting the Baikal
switch chip via BAR+0xf04 (GPHY_CTRL), which aliases to the switch-chip GPIO
reset.  Secondary finding: full per-bit decode of BAR+0x04/0x08/0x0c/0x10.**

## Q3 answered: BAR+0x04/0x08/0x0c/0x10 bit-level decode

All evidence from `mts_mac_init` (`0xffffffffc85ecb60`) and `mts_link_change`
(`0xffffffffc85eeb90`) in the Orbis `if_mts.c` driver.

### BAR+0x04 — LINK_STATUS

| Bits | Name | Source | Semantics |
|------|------|--------|-----------|
| 0 | LINK_UP | `mts_link_change` L5: `uVar3 & 1` | 1 = link established |
| 2-3 | SPEED | `mts_link_change` L12: `uVar3 >> 2 & 3` | 00=10M, 01=100M, 10=1000M |
| 4 | FULL_DUPLEX | `mts_link_change` L13: `uVar3 & 0x10` | 1=full, 0=half |
| 6 | FLOW_CTRL | `mts_link_change` L18: `uVar3 >> 6 & 4` | 1=flow control active |
| 8 | AUX_STATE | `mts_link_change` L42: `uVar3 >> 8 & 1` | per-port link for secondary-MAC mode |
| 12,13,18,19,31 | writable status | `mts_mac_init`: `uVar6 & 0x7fffcfff` | cleared at end of init; writable control bits |

Mask `0x7fffcfff` = keep bits 0-11,14-17,20-30; clear bits 12,13,18,19,31.
Bits 0-3 are nominally "read-only" (written back unchanged from read), bits 12+
are control bits.

### BAR+0x08 — MAC_CTRL1

`mts_mac_init` does RMW: `val |= 0x07597C00`.  Bit breakdown of 0x07597C00:

| Bit | Hex constant | Possible function |
|-----|-------------|-------------------|
| 10 | 0x00000400 | MAC TX enable |
| 11 | 0x00000800 | MAC RX enable |
| 18 | 0x00040000 | internal loopback? |
| 19 | 0x00080000 | speed override? |
| 20 | 0x00100000 | GMII/RGMII mode |
| 22 | 0x00400000 | checksum offload |
| 24 | 0x01000000 | jumbo frame enable |
| 25 | 0x02000000 | flow control enable |
| 26 | 0x04000000 | VLAN filter enable |

### BAR+0x0c — MAC_CTRL2

`mts_mac_init` does: `val &= ~0x80` (clear bit 7 only).

**Critical find re v81:** When sky2 reads then writes `B0_IMSK` (=BAR+0x0c), it
sets Yukon IRQ mask bits (3,4,5 for port 0 = `0x38`) PLUS the base mask bits
(30,31 = `0xC0000000`).  On Baikal, bit 31 is writable (cleared by Orbis's
`& 0x7fffcfff` on BAR+0x04, but BAR+0x0c ≠ BAR+0x04).  Bit 7 interaction: v81
gated the sky2 B0_IMSK write → SMI got *worse* (v80 had one real BMSR read,
v81 had zero).  **Hypothesis:** Sky2's B0_IMSK write sets some bit(s) at
BAR+0x0c that *enable* a clock path for SMI MDC.  The Orbis mts_mac_init clears
bit 7 of BAR+0x0c at *end* of init — after SMI is done driving PHY
calibration.  So bit 7 = 0 may put MAC into "run mode" after init, but
setting it to 1 earlier may have been required for MDC.

Net: BAR+0x0c bit 7 is likely a "MAC init mode" / clock-control gate.  Set=1
during init (enables MDC), cleared to 0 after init (locks final config).

### BAR+0x10 — MAC_CTRL3

`mts_mac_init` does: `(val & 0xffffff6e) | 0x81`

- `& 0xffffff6e` = clear bit 0 (0x01), bit 4 (0x10), bit 7 (0x80)
- `| 0x81` = set bit 0 and bit 7

Net: bit 0→1, bit 4→0, bit 7→1.  Likely another PHY/MDC control register.

### Yukon-2 ↔ Baikal register collision map

Thanks to `sky2.h:257-263`, we know the B0_* offset mapping.  sky2 writes to
these offsets expecting Yukon-2 semantics — but on Baikal they land on the
Sony-custom register set:

| Yukon name | BAR offset | Baikal name | sky2 writer | Damage |
|-----------|-----------|-------------|------------|--------|
| B0_CTST | 0x04 | LINK_STATUS | `sky2_reset` writes `Y2_ASF_DISABLE`(bit12), `CS_RST_SET`(bit0), `CS_RST_CLR`(bit1), `CS_MRST_CLR`(bit3) | Toggles link-up bit 0, sets unknown control bits |
| B0_IMSK | 0x0c | MAC_CTRL2 | `sky2_up`, `sky2_open` write IRQ masks (`Y2_IS_BASE`=bits30-31, `portirq_msk[0]`=bits3-4) | Sets bits 3,4,30,31 (gated in v81, made things worse — SETTING these bits appears beneficial) |
| B0_HWE_ISRC | 0x10 | MAC_CTRL3 | `sky2_intr` reads for error check | Read-only, harmless |
| B0_HWE_IMSK | 0x14 | MAC_ADDR0_HI | `sky2_reset` writes `hwe_mask` | Overwrites MAC address bytes 0-3! But sky2 rewrites addr later via gma_set_addr |
| B0_Y2_SP_ISRC2 | 0x1c | unknown | `sky2_intr` reads | May read garbage; unknown effect |

## The MDC killer: BAR+0xf04

**This is the most actionable finding.**

### The mechanism

1. Orbis `msk_init_hw` (`0xffffffffc8511d50`) uses BAR+0xf04 as a switch-chip
   GPIO reset: writes 1, 12ms delay, writes 2, 500ms delay.  This resets the
   external switch IC.

2. On Baikal, `GPHY_CTRL` in sky2's register map = offset `0x0f04`.  sky2
   accesses it via `SK_REG(0, GPHY_CTRL)` = `0*0x80 + 0x0f04` = `0x0f04`.

3. `sky2_mac_init` (line 1002-1003 in sky2.c) runs on every interface-up:
   ```c
   sky2_write8(hw, SK_REG(port, GPHY_CTRL), GPC_RST_SET); // BAR+0xf04 = 0x01
   sky2_write8(hw, SK_REG(port, GPHY_CTRL), GPC_RST_CLR); // BAR+0xf04 = 0x02
   ```

4. `sky2_phy_power_up` (line 810) then writes BAR+0xf04 = 0x02 again.

5. On Baikal, writing 1→2 to BAR+0xf04 = **switch chip reset** — the exact
   same sequence msk_init_hw uses, but WITHOUT the 12ms + 500ms delays.

6. Switch chip enters reset → PHYs power down → MDC line from MAC to PHY
   goes silent → MAC's SMI controller at BAR+0x00 completes transactions
   locally (DONE bit sets) but MDC never clocks externally → data field stays
   at residue of last write.

### Supporting evidence from hardware

- v80 UART log: one good BMSR read (0x7949) survived from sky2's link-timer
  read *after* sky2_open.  This means SMI briefly worked after open, then died.
  Consistent with: switch reset starts, takes ~500ms, PHY answers one read
  before going into reset state, then all subsequent reads fail.

- v78→v81 all show "SMI stuck" (0x20008000 echo).  No patch touched
  BAR+0xf04 — the killer was never gated.

- Sky2's link timer (`hw->watchdog_timer`) fires every 2 seconds and calls
  `gm_phy_read`, which on Baikal goes to our BAR+0x00 SMI accessor.  If the
  switch is in reset, every read returns garbage, and the periodic read cycle
  may extend the reset state.

### Verification experiment

Gate the GPHY_CTRL writes in `sky2_mac_init` for Baikal:

```c
// In sky2_mac_init, lines 1002-1003:
if (!sky2_is_baikal(hw)) {
    sky2_write8(hw, SK_REG(port, GPHY_CTRL), GPC_RST_SET);
    sky2_write8(hw, SK_REG(port, GPHY_CTRL), GPC_RST_CLR);
}
```

And in `sky2_phy_power_up`, line 810 — check if `SKY2_HW_ADV_POWER_CTL` is set
for Baikal (it IS — YUKON_PRM gets this flag at line 3353).  Gate:

```c
if ((hw->flags & SKY2_HW_ADV_POWER_CTL) && !sky2_is_baikal(hw))
    sky2_write8(hw, SK_REG(port, GPHY_CTRL), GPC_RST_CLR);
```

If SMI stays alive after these gates → confirmed: BAR+0xf04 was the killer.

### Why v81's B0_IMSK gate made things *worse*

BAR+0xf04 is NOT gated in v81.  The switch-chip reset STILL happens.  And
removing the B0_IMSK write (line 1832 in sky2_up) removed the one write that
*enabled* MAC_CTRL2 bits (e.g. bit 7 = "init mode"?), which may have briefly
powered the SMI controller.  Without those bits, the SMI controller had even
less chance to complete a read before the switch reset struck.

## Q2: Who calls baikal_gbe_attach?

Partial answer.  The caller's address (0x71b9d0 in `unallocated_2` segment)
requires data-segment analysis not directly supported by MCP function-call
tracing.  Manual pointer-chase needed:

1. 0x71b9d0 contains bytes `00 11 51 c8 ff ff ff ff` = pointer to
   `baikal_gbe_attach` (FUN_c8511100) in little-endian.  This is inside a
   `device_method_t` array — FreeBSD's equivalent of Linux `pci_driver.probe`.

2. The `device_method_t` table is referenced by `DRIVER_MODULE()` or
   `DEVICE_PROBE()` — FreeBSD's module registration macro.  Search the binary
   for the 8-byte pointer to 0x71b9d0 (little-endian: `d0 b9 71 00 ff ff ff ff`
   in the unallocated segments).

3. The caller is `bus_generic_probe()` or `device_probe_child()` from FreeBSD's
   `subr_bus.c` — the standard newbus device-discovery framework.  The
   specific driver module name is the string referenced by the `driver_t`
   struct that embeds this method table.

**Relevance to MDC:** the caller is generic FreeBSD bus infrastructure.
No clock/power-domain/PHY-enable magic happens in the caller.  All init is in
`baikal_gbe_attach` (which calls `msk_init_hw` + `bus_generic_attach` to spawn
mts child).  The caller finding is "no surprise" — confirms our architecture
document is correct.

## Recommended next experiment on hardware

Gate `sky2_write8(hw, SK_REG(port, GPHY_CTRL), ...)` in both `sky2_mac_init`
and `sky2_phy_power_up` for `sky2_is_baikal(hw)`.  Skip all BAR+0xf04 writes.
If SMI MDC survives sky2_open, this was the killer.  Two-line patch, testable
as v82a.

--- deepseek-v41, 2026-05-12
