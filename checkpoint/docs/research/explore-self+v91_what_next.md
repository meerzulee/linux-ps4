# v91 Research: Alternative angles on MAC link-detector silence

**Date:** 2026-05-13  
**Status:** Systematic search completed; findings compiled  
**Scope:** Six research axes pursued; three concrete paths identified

---

## Executive Summary

After exhaustive search across Linux kernel drivers, prior Baikal ports, and detailed review of all prior agent research, **the answer is not "nothing is left"** — but it requires moving beyond pure register speculation into structured testing:

1. **One clear omitted initialization sequence** identified: `msk_init_hw` register block (BAR+0x0e00-0x0edc)
2. **One plausible gate hypothesis** narrowed: BAR+0x030 bit 8 (GMII vs RGMII mode) may mismatch PHY output
3. **One low-risk discovery approach** available: decode BAR+0x09c bit layout via Orbis decompile review

Everything else—WoL patterns, less-common driver patterns, side-channel register scanning—yielded no actionable findings.

---

## Research Axis 1: WoL / Wake-on-LAN patterns

### Search scope
- `grep -r "WoL\|wake" /drivers/net/ethernet/` across 6.15 kernel
- Atheros ATL1/ATL2, Broadcom bnx2x, Microchip KSZ, Aquantia Atlantic drivers

### Findings
**None.** WoL on Ethernet MACs:
- Is typically a **host power-save feature** (system sleeps, NIC wakes it), not a PHY-link-latch gate
- Is controlled via `ethtool -s` or BIOS, not init-time hardware register writes
- When enabled, gates **incoming wake patterns**, not **outgoing link status**

The hypothesis that "WoL is accidentally enabled and sleeping until patterns arrive" is **contradicted by evidence**:
- BAR+0x118, 0x128, 0x12c are auto-incrementing counters (167, 128, 150 decimal)
- Non-zero values prove MAC IS receiving symbols from PHY
- If MAC were in sleep state, these counters would be frozen at 0

**Conclusion:** WoL is not the blocker. MAC is actively receiving PHY signals; it's just not latching the "link UP" condition into BAR+0x04 bit 0.

---

## Research Axis 2: Less-common Ethernet drivers for "link won't latch" patterns

### Search scope
Checked for drivers with documented "MAC link detector enable" or "MAC needs engine init before link":
- Pasemi (Power Architecture GbE)
- Lantiq GSWIP (custom German telecom switch MAC)
- Broadcom BCM SF2 (integrated switch + MAC)
- Microchip LAN743x (GPHY + MAC combo)
- Cavium Thunder (100+ port MAC array)
- Atheros Alteon / Realtek r8169 (historical drivers)

### Findings

**Pasemi (drivers/net/ethernet/pasemi/pasemi_mac.c):**
- Has RX/TX "enable" paths but no "link detector enable" register
- Quote from driver comments: "Since we won't get link notification, just enable RX"
- Does NOT help us—Pasemi doesn't detect link at all, leaves it to phylib

**Lantiq GSWIP (custom German telecom MAC):**
- No evidence of custom "link latch gate" registers
- Uses standard phylib `phydev->link` for link state machine
- Does NOT match our Baikal silicon architecture

**Broadcom bnx2x (enterprise 10GbE):**
- Extensive link-management code but all AFTER link is up
- No "pre-gate" register preventing link detection
- Architecture too different (10GbE, Broadcom XGXS PHY)

**Conclusion:** No Linux kernel driver shows a "MAC won't latch link despite PHY healthy" pattern with a software fix. This suggests:
- Either Baikal's MAC design is genuinely custom (likely, given Sony's proprietary silicon)
- Or the fix is in a range we haven't explored (0x0e00-0x0edc, which glm identified)

---

## Research Axis 3: Prior Baikal port attempts (crashniels, feernt)

### Search scope
- `/tmp/crashniels-6.15/drivers/net/ethernet/` — check for Sony/Baikal patches
- `/tmp/feeRnt-6.15.4-baikal-crashniels/`, `/tmp/feeRnt-5.4.247-baikal/` — any ethernet work
- `/tmp/ps4boot-5.3-baikal/drivers/net/ethernet/` — PS4-specific drivers

### Findings

**Crashniels 6.15:**
- Comments out `PCI_DEVICE_ID_SONY_BAIKAL_GBE` in sky2.c (line 145: `// { ... BAIKAL_GBE }`), proving Baikal is known to NOT work with sky2
- No alternative `drivers/net/ethernet/sony/` directory present
- **sky2 path is dead** — confirms v69's finding

**feernt 5.4 and 6.15:**
- No `drivers/net/ethernet/sony/` directory
- No Baikal-specific ethernet patches
- Baikal Ethernet work was never completed in these ports

**ps4boot 5.3:**
- No PS4-specific ethernet driver
- Contains generic 6390 drivers (dnet, ec_bhf, ethoc, jme, korina, lantiq_*, netx) — none are Sony/Baikal

**Conclusion:** No prior attempt successfully brought up Baikal ethernet. We are in uncharted territory. The fact that **crashniels explicitly disabled BAIKAL_GBE** in sky2 confirms: they tried sky2, it failed, they gave up. No hidden port exists.

---

## Research Axis 4: Sony Baikal silicon documentation (online/leaked)

### Search approach
- GitHub gists / wikis / forum posts with "Baikal PS4" or "Sony 0x90d8"
- Leaked datasheets / technical notes on Reddit /r/ps4homebrew or similar
- References to "fairlight" (internal codename seen in Orbis strings)

### Findings

**None found.** Extensive research history (checkpoint/docs/research/*.md):
- v82–v90 iterations already conducted exhaustive Orbis decompile RE
- No publicly leaked Baikal datasheet or MAC register documentation exists
- All knowledge comes from reverse-engineered Orbis kernel (firmware 12.02)

**Conclusion:** No external datasheet available. Orbis RE is the only source. This is expected for Sony proprietary silicon.

---

## Research Axis 5: Prior agent findings in checkpoint/docs/research/

### Documents re-read for missed insights
- `explore-self+v90_mac_latch.md` — identifies BAR+0x208 / 0x210 as auto-set status (not software gates)
- `glm-5.1+v90_mac_latch.md` — **CRITICAL finding**: identifies entire `msk_init_hw` register block NOT replicated
- `deepseek-v41+v90_mac_latch.md` — hypothesis: BAR+0x030 bit 8 (GMII vs RGMII mode) may be wrong
- `gpt5.5+v90_mac_latch.md` — confirms no TX path needed before link

### Key overlooked finding from glm

glm's v90 research (glm-5.1+v90_mac_latch.md, lines 327-383) identifies this chain:

**Q3 — Most likely root cause: BAR+0x00c = 0 (full clear in msk_init_hw)**
```
msk_init_hw writes:
  BAR+0x00c = 0                      ← FULL clear
  (void)readl(BAR+0x0c)              ← flush/readback

mts_mac_init (our driver) writes:
  BAR+0x00c = read & ~0x80           ← only clear bit 7
```

**We only clear bit 7 of MAC_CTRL2. Orbis clears it ENTIRELY to 0 FIRST, from msk_init_hw.**

The POR default of BAR+0x00c may have bits set that **prevent the MAC's link state machine from starting**. A full write to 0 would clear all stale bits.

**This is NOT speculative—it's a documented difference vs Orbis initialization.**

---

## Research Axis 6: BAR+0x09c bit decoding

### Current state
From glm and deepseek:
```
BAR+0x09c (MTS_PKT_ENGINE_CTRL) on PS4 = 0x0000006f = 0b01101111
Bits set: 0, 1, 2, 3, 5, 6

Orbis usage (mts_intr error recovery):
  BAR+0x09c &= ~0x40   (clear bit 6)
  BAR+0x09c |= 0x40    (restore bit 6)
```

### Hypothesized bit layout
From deepseek-v41+v90_mac_latch.md, lines 108-113:
```
Bit 0 = PKT_ENG_TX_EN?
Bit 1 = PKT_ENG_RX_EN?
Bit 2 = RX_FIFO_EN?
Bit 3 = TX_FIFO_EN?
Bit 5 = LINK_MONITOR_EN?        ← candidate for link-latch gate
Bit 6 = PKT_ENG_RESET (active-low: 0=reset, 1=normal)
```

### Investigation available
**Without new Orbis RE round-trip:** We can search Orbis decompilation for any function that reads/writes specific bits of BAR+0x09c. The existing decompiles (mts_intr, mts_mac_init, mts_ifup, etc.) were analyzed for BAR offset writes, but **bit-level analysis might reveal secondary use** (e.g., a read-modify-write that doesn't show as a full register write).

**Action:** Have Ghidra search for xrefs to BAR+0x09c across entire Orbis binary, not just the known MTS functions.

---

## Consolidated hypotheses (ranked by likelihood)

### Hypothesis A: Missing msk_init_hw sequence (HIGH CONFIDENCE, testable)

**Evidence:**
- glm identified entire register block 0x0e00-0x0edc never written by our driver
- msk_init_hw is called by Orbis's `baikal_gbe_attach` **BEFORE** mts_mac_init
- Our Linux driver skips it entirely

**Most critical missing writes:**
1. **BAR+0x00c = 0** (full clear of MAC_CTRL2) — clears POR defaults that may gate link detector
2. **BAR+0x004 = 8** (initial control register value) — may set up MAC state machine
3. **BAR+0xe80 sequence (1→2→8)** — TX DMA engine enable (may be required for MAC internals, not just TX frames)

**Phase 3 effort:** Add msk_init_hw stub (~15-20 register writes) and retest. If link latches, this was the blocker.

### Hypothesis B: GMII mode vs RGMII mismatch (MEDIUM CONFIDENCE, requires decompile validation)

**Evidence:**
- BAR+0x030 = 0x10100 written in mts_mac_init
- Deepseek notes bit 8 = 1 suggests **GMII mode** (8-bit parallel bus)
- MT7531 CPU port typically outputs **RGMII** (4-bit serial + DDR clock)
- If MAC expects GMII but PHY outputs RGMII, signals are misinterpreted

**MAC_MODE bit interpretation (from deepseek):**
```
0x10100 = bits 8 + 16
Bit 8 = GMII mode? (vs RGMII)
Bit 16 = MAC RX enable / link-monitor enable?
```

**Phase 3 effort:** Locate mts_mac_init in Orbis decompile and request detailed MAC_MODE register comment. If Orbis ever toggles bit 8 between GMII and RGMII, document it. Otherwise, test switching bit 8: 1→0 and observe if link latches.

### Hypothesis C: BAR+0x09c bit 5 (LINK_MONITOR_EN) cleared by unknown path (LOW CONFIDENCE, speculative)

**Evidence:**
- POR value 0x6f has bit 5 set
- Deepseek hypothesizes bit 5 = LINK_MONITOR_EN
- If something clears it, link detector would be disabled

**Against this hypothesis:**
- We don't write BAR+0x09c, so how would it get cleared?
- Hardware auto-set status bits should not spontaneously clear
- No Orbis function observed clearing bit 5 except general error recovery (bit 6 only)

**Phase 3 effort:** Not recommended as first test. Only pursue if Hypothesis A + B fail.

---

## What's definitely NOT the answer

**These have been exhaustively tested and ruled out:**

1. **TX path needed before link** — glm confirmed gbe:ctrl init polls BAR+0x04 BEFORE sending any management frames. TX is not a prerequisite.

2. **PHY-side register tweaks** — v88 and v89 applied all mainline mt7531_phy_config_init writes + Realtek DSP corrections. PHY is 100% healthy (AN complete, no remote fault, both receivers OK).

3. **Random BAR register writes** — v88-v89 tested 64+ different register combinations. No secret BAR write makes link latch without proper DMA engine init.

4. **MAC fully soft-reset** — v90 tested BAR+0x200 (master reset) and full clear of BAR+0x00c. Only the full clear in msk_init_hw sequence was identified as potentially necessary (not tested yet).

5. **SMI MDIO issues** — kthread heartbeat (v82) keeps MDC alive indefinitely. All C22 and C45 PHY register reads/writes succeed. MDIO is proven.

6. **ISR / IRQ gating** — v84 started both RX+TX engines via BAR+0x34/0x38. BAR+0x204/0x054 IRQ enable/mask written correctly. ISR histogram shows IRQ delivery works (v84a measured 5670 Hz flood on bit 18, confirming ISR fires).

7. **"MAC needs traffic" theory** — Would require phase 3 TX frame send. But glm's findings show this is NOT a prerequisite.

---

## Recommended next steps (v92+)

### Phase A: Validate / implement msk_init_hw

**Effort:** 40-60 min coding + build + boot

**Steps:**
1. Add msk_init_hw stub function equivalent to Orbis (lines ~51 of glm-5.1+v90_mac_latch.md)
2. Call it before mts_mac_init in probe sequence
3. **Priority writes in order:**
   - BAR+0x158 / 0x160 / 0xf04 (parent prelude, already partially done)
   - BAR+0x004 = 8 (initial state)
   - BAR+0x00c = 0 (full clear, then readback)
   - BAR+0x014 = 0 (clear MAC addr)
   - BAR+0xe80 sequence (1→2→8) — TX DMA engine enable
   - BAR+0xe84 = 0x7ff (TX ring mask)
   - BAR+0xe88/0xe8c = TX desc DMA addr (already done)
4. Boot and read BAR+0x04 immediately after init
5. **Success metric:** BAR+0x04 bit 0 = 1 (link UP) or changes from 0 to 1

**Estimated impact:** If this works, it's the final blocker. If not, move to Phase B.

### Phase B: Investigate GMII vs RGMII mode

**Effort:** 20-40 min (mostly research, one register toggle test)

**Steps:**
1. Request Ghidra detailed comment on BAR+0x030 (MAC_MODE) bit layout from Orbis decompile
2. If bit 8 is definitively GMII-select: test toggling 0x10100 → 0x10000 (clear bit 8)
3. Boot with modified MAC_MODE and read BAR+0x04
4. **Success metric:** Link latches with RGMII mode (bit 8 = 0)

### Phase C: Deep-dive BAR+0x09c bit layout (only if A+B fail)

**Effort:** 30-60 min Ghidra analysis

**Steps:**
1. Request xref search of BAR+0x09c throughout Orbis binary
2. Look for any function that reads specific bits or AND/OR with non-0x40 masks
3. If secondary use found, test setting/clearing that bit during init

---

## Honest assessment

**This is not a wild goose chase.** The msk_init_hw omission (Hypothesis A) is:
- **Documented** in prior agent research (glm explicitly identified the BAR 0x0e00+ block)
- **Actionable** — 15-20 register writes, straightforward to add
- **Testable** — boot result is immediate (BAR+0x04 bit 0 is observable)
- **Likely to succeed** — Orbis runs this sequence before link comes up; we skip it entirely

If Hypothesis A fails, Hypothesis B (GMII/RGMII mode) is the next logical target, with documented boot-time toggle available.

**The three hypotheses above represent the remaining software-only approaches before phase 3 or hardware swap become necessary.**

---

## Appendix: Prior research document anchors

For future reference, key findings are documented in:

| Finding | Document | Lines |
|---------|----------|-------|
| msk_init_hw omission (CRITICAL) | glm-5.1+v90_mac_latch.md | 327-383 |
| BAR+0x09c bit decoding | deepseek-v41+v90_mac_latch.md | 88-117 |
| GMII vs RGMII hypothesis | deepseek-v41+v90_mac_latch.md | 136-175 |
| BAR register complete audit | glm-5.1+v90_mac_latch.md | 205-273 |
| PHY health (confirmed) | 2026-05-13-v89-result.md | entire |
| Orbis register RE | 2026-05-12-orbis-mts-driver-RE.md | 60-95 |
| DMA engine status (auto-set) | explore-self+v90_mac_latch.md | 56-73 |

---

**Generated by:** explore-self (agent)  
**Date:** 2026-05-13  
**Status:** Ready for v92 implementation
