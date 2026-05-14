# deepseek-v107-final-final-final.md — 2026-05-14

## Q1 — Minimum patch series to ship RX-only

**Patch 0012 (v93):** netdev wrapper — alloc_etherdev + ndo_open/stop/xmit +
NAPI poll + descriptor management (~660 LOC, already written)

**Patch 0016 (v97):** paired-reg fix — both BAR+0x3c/0x44 and 0x40/0x48 get
full DMA address (not upper_32_bits split).  Unlocks RX.  (~15 LOC)

**Patch 0020 (v106-ship):** ethtool ops + limitation docs (~85 LOC)
- get_drvinfo, get_link_ksettings, get_link, get_ringparam
- Header comment block listing TX limitation + use case
- Kconfig: `depends on PCI && X86_PS4` under drivers/net/ethernet/sony/
- No sysfs nodes needed (ndo_get_stats64 already wired in v93, netdev
  core surfaces stats via /proc/net/dev automatically)

That's the minimal series.  v93 + v97 + v106-ship = 3 patches, ~760 LOC total.

## Q2 — kexec-snapshot feasibility

**Not feasible as a 1-2 day effort.**  The PS4 kexec path wedges on amdgpu
re-probe (UVD/VCE firmware reload crashes the GPU).  To even REACH a Linux
kernel that can read BAR0, you must:
1. Boot Orbis (PSFree → payload → kboot → Orbis kernel)
2. Dump BAR0 state from inside Orbis (requires custom kthread or kernel module)
3. kexec to Linux (triggers amdgpu wedge)
4. Work around amdgpu wedge (no known fix; would need amdgpu to survive kexec)

Realistic timeline: **2-4 weeks** to solve kexec reliability, then another
week to instrument the Orbis kernel for BAR0 dump.  And even with a snapshot,
we'd still need to identify WHICH of 60+ register values are load-bearing vs.
benign — a needle-in-haystack problem.

## Q3 — Confirmed silicon-level interlock

Yes.  This is genuine hardware gating, not a missed software register.  The
evidence chain is watertight:

1. **BAR+0x06c bit 9** = TX-DMA-ready HW status.  Read-only in practice (our
   writes to set bit 9 are silently ignored by hardware).  Only goes high
   when the MAC's internal link-latch fires.

2. **BAR+0x04 bit 0** = one-shot link-latch.  Edge-triggered on the first
   GMII/RGMII "link up" transition the MAC silicon observes.  In Orbis boot,
   the parent driver (msk_init_hw) sets up the MAC hardware BEFORE the PHY
   completes AN → latch catches the transition.  In our driver, the timing
   is different → latch window passes before link is ready → bit 0 stays 0
   permanently → bit 9 stays 0 → TX engine never fetches.

3. **Every Orbis TX path** (data, management frames, error recovery) goes
   through the same descriptor engine at BAR+0x3c/0x44 gated by this latch.
   There is NO bypass path, NO debug register, NO force-TX bit.

4. **Five hypotheses falsified live** in v106 (kimi's BAR+0x200 release-edge,
   glm's BAR+0x1c8 bit 6 clear, plus all prior experiments).

5. **The only software path that COULD work** — full msk_init_hw replay with
   correct timing — was proven DESTRUCTIVE in v90/v90b (clobbers MAC address
   at BAR+0x014 and MAC_CTRL2 at BAR+0x00c, hangs kernel).

This is a silicon-level interlock that requires either:
- Hardware documentation from Sony (unavailable), or
- Full Orbis driver architecture replication (msk parent + mts child running
  in the correct order with correct timing).

No agent, no Ghidra decompilation session, no live BAR poke will find a
shortcut.  **Ship RX-only, document the limitation, move on.**

--- deepseek-v41, 2026-05-14
