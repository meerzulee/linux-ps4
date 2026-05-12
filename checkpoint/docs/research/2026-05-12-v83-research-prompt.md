# Research prompt — PS4 Baikal ethernet v83/post-v82 link bring-up

**Copy-paste this verbatim to a fresh AI agent.**  The agent should have
Ghidra MCP available on the `orbis-ps4-dump` project (Orbis FW 12.02
ELF, base 0xffffffff_c8000000) and write findings to
`checkpoint/docs/research/<agent_name>+v83_link_research.md` and
nothing else.  Do NOT edit code or other files.

---

## Context (where we are, 2026-05-12 evening)

I'm porting Linux to PlayStation 4 Baikal hardware.  We've been working
through ethernet bring-up for the Baikal southbridge GBE controller
(PCI 0x104d:0x90d8) and just shipped **v82** — a major breakthrough.

### What works (v82 confirmed on hardware)

- `ps4_mts.c` standalone Linux driver binds to the device.
- Sony custom SMI MDIO controller at BAR0+0x00 — C22 protocol
  reverse-engineered and working: ARM (write 0x8000), then
  `0x4000 | (reg<<8)` for OP_C22_RD, poll bit 15 for DONE, read data
  from upper 16 bits.
- Full PHY register sweep works.  PHY identified as **MediaTek MT7531**
  (ID = 0x03a29441, matches mainline `MTK_GPHY_ID_MT7531` in
  `drivers/net/phy/mediatek/mtk-ge.c`).
- BMSR (reg 1) = `0x7969` — AN-complete bit (bit 5) is SET.
- Link partner ability (reg 5) = `0xc5e1` — partner is advertising
  10/100 + pause, cable IS connected.
- **SMI MDC clock is sustained across >5 min uptime** thanks to a
  3-second-cadence BMSR-reading kthread (`[ps4_mts_phy_ctrl]`).  This
  was THE breakthrough — v78..v81 had MDC dead at ~1 min.
- BAR-level state matches Orbis:
  - `BAR+0x54 irq_mask = 0x007bfffe` ✅
  - `BAR+0x204 irq_enable = 0x10001388` ✅
  - `BAR+0x50 irq_status = 0x00040002` (bits 1, 18 pending, no ISR yet)
- The full parent-prelude sequence (Orbis `FUN_c85131d0`) is replayed
  in `mts_probe`: BAR+0xf10 1→2, BAR+0xf04 1+12ms+2+500ms, BAR+0x60..6c
  constants, BAR+0x120/0x11c/0x158 with mode 2→1 latch.
- The full `mts_mac_init` sequence (Orbis `FUN_c85ecb60`) runs: MAC_CTRL1
  OR 0x07597c00, MAC_CTRL2 clear bit 7, MAC_CTRL3 mask + OR, MAC_MODE,
  MAC_PAUSE, RX_GATE, MAC_CLK, plus the IRQ block bring-up.

### What DOESN'T work yet

- **Physical link is DOWN** despite PHY reporting AN-complete + partner
  advertising.  `linkreg = 0x00000b18`:
  - bit 0 = 0 → **link DOWN** (this is the problem)
  - bits 2-3 = 10 → speed = 1000 Mbps
  - bit 4 = 1 → full duplex
  - bit 8 = 1 → aux state
  - The MAC reports a speed/duplex even though link is down — odd.

- BMSR's link-status bit (bit 2) is also 0, consistent with linkreg.

- No netdev allocated yet (phase 3 work — `register_netdev`, TX/RX
  rings).  That's intentional; we want link UP first.

### What I'm building right now (v83) — for context

I just shipped v83 which extends the `phy_ctrl` kthread to ALSO do AN
restart when link is down.  Mirrors Orbis `FUN_c85f0480` event 0x1
exactly:
- reg 9 (1000-BT control) |= 0x0200 if not set
- reg 4 (ANAR) |= 0x0180 if not all set
- BMCR (reg 0) |= 0x1200 (AN enable + AN restart)

Triggered on:
- First iteration (initial bring-up from boot)
- Every UP→DOWN transition
- Every 5 iterations (~15s) while link stays down

**You don't need to verify v83's code.**  Assume it works as described.
The question is: **if v83 still doesn't bring up the link, what's the
next thing to investigate?**

## What I want from you

Use the Ghidra MCP project `orbis-ps4-dump` to dig deeper into Orbis's
link bring-up.  Specifically:

### Question 1 (HIGH priority)

**What does Orbis do BETWEEN `mts_mac_init` and `mts_ifup` that we're
missing?**  Specifically:

- After `baikal_gbe_attach → msk_init_hw → child_attach (mts_attach →
  mts_mac_init)`, is there a MT7531-specific PHY init sequence in
  Orbis that we don't replay?
- The MT7531 has switch-mode and non-switch-mode operation.  Does
  Orbis configure it as a 1-port PHY or as a switch chip with VLAN
  setup?  Look for SMI C45 (MMD) writes in `mts_attach`,
  `mts_mac_init`, or any `mts_*` function — these target vendor
  registers via MMD page selection.
- Are there efuse-driven trim values being written?  We deliberately
  skip these in our `mts_mac_init` because we don't have efuse access
  yet — would they affect link bring-up?
- `mts_link_change` (FUN_c85eeb90) handles link state transitions in
  Orbis.  Does it write anything to the MAC or PHY beyond the
  BAR+0x04 readback + speed/duplex extraction?

### Question 2 (HIGH priority)

**What does Orbis's `mts_ifup` (FUN_c85ec940) do that ENABLES the link
to come up?**

- Decompile the function fully.  Look for:
  - SMI writes via `mts_smi_cl22_*` or `mts_smi_cl45_*` to the PHY
  - BAR writes that we don't do in `mts_mac_init`
  - Calls to other Orbis functions that might do PHY init
- We've found that `mts_init_rings_kick` is called from here (and from
  gbe:ctrl thread) but that's TX/RX setup, not link bring-up.  Is
  there something else?

### Question 3 (MEDIUM priority)

**What gates linkreg bit 0 in the Baikal MAC silicon?**

- BAR+0x04 is documented as `LINK_STATUS` in our RE notes.  Bit 0 =
  "link up" is set by the MAC when it sees the PHY assert link via
  some internal signal (probably an MII/RGMII LinkStatus signal).
- Does Orbis explicitly set bit 0 anywhere, or is it purely passive
  (the MAC sets it based on PHY signaling)?
- Look at `mts_link_change` and `mts_intr` — both touch BAR+0x04.
  What do they write vs read?
- Is there a MAC-side "force link up" mode we need to enable for
  a specific PHY type?

### Question 4 (LOWER priority but useful)

**Are there MT7531-specific writes in Orbis that mainline Linux's
`mt7530-mdio.c` does?**

- mainline mt7530-mdio.c does extensive MMD (C45) writes to MT7531's
  vendor registers for PLL config, RGMII timing, etc.
- Look for SMI C45 (operation 0x60 / 0xe0) writes in `mts_*` functions
  — these target MMD pages.
- If Orbis writes any of these, that's what's missing from our driver.

## Constraints

- Do NOT edit any code or .c/.h files.  Only write your research file.
- Do NOT recommend running on hardware — I'll do that.
- Be SPECIFIC: cite Ghidra function addresses (FUN_cXXXXXXXX) and
  decompile excerpts.  Don't speculate without evidence.
- If you find a register sequence in the binary, give me the exact
  writes (offset, value, order, any delays).
- Write your findings to
  `checkpoint/docs/research/<your-name>+v83_link_research.md`.
  Replace `<your-name>` with something identifying like `kimi-k2.7`,
  `deepseek-v42`, `glm-5.2`, `gpt-5.6`, etc.
- One file per agent.  Do not edit other agents' files.

## Key Ghidra anchors (already RE'd by prior agents)

| Function | Address | Notes |
|---|---|---|
| `baikal_gbe_attach` | `0xffffffffc8511100` | parent attach, calls msk_init_hw |
| `msk_init_hw` | `0xffffffffc8511d50` | Yukon-2-derived hardware init |
| `FUN_c85131d0` | `0xffffffffc85131d0` | parent prelude (we replay this) |
| `mts_attach` | `0xffffffffc85ec030` | MTS child attach |
| `mts_mac_init` | `0xffffffffc85ecb60` | MAC init register sequence (we replay this) |
| `mts_ifup` | `0xffffffffc85ec940` | interface up — **investigate this** |
| `mts_init_rings_kick` | (search) | TX/RX ring setup, called from ifup |
| `mts_link_change` | `0xffffffffc85eeb90` | link state transition handler |
| `mts_intr` | (search) | ISR walking BAR+0x50 status |
| `gbe:ctrl` kthread body | `0xffffffffc85f0190` | event 0x2 toggles BAR+0x54 bit 12 |
| `gbe:phy_ctrl` kthread body | `0xffffffffc85f0480` | event 0x1 = AN restart; we mirror this |
| `mts_smi_cl22_read` | (search) | SMI C22 read primitive |
| `mts_smi_cl22_write` | (search) | SMI C22 write primitive |
| `mts_smi_cl45_read` | (search) | SMI C45 (MMD) read primitive |
| `mts_smi_cl45_write` | (search) | SMI C45 (MMD) write primitive |

## Prior agent findings (read first to avoid duplication)

- `checkpoint/docs/research/glm-5.1+ethernet_research.md` — gbe:phy_ctrl
  body decompile, MT_STOP path
- `checkpoint/docs/research/kimi-k2.6+ethernet_research.md` — kthread
  hypothesis (CONFIRMED on hardware in v82)
- `checkpoint/docs/research/gpt5.5+ethernet_research.md` — parent prelude
  + BAR+0x158 mode sequencing
- `checkpoint/docs/research/deepseek-v41+ethernet_research.md` —
  BAR+0xf04 switch reset + Yukon/Baikal collision map

Your findings should COMPLEMENT these (not duplicate).  Focus on
**what comes after `mts_mac_init` to actually bring the link UP**.
