# Research prompt — PS4 Baikal ethernet v85 (post-v84a)

**Copy-paste this verbatim to a fresh AI agent.**  The agent should have
Ghidra MCP available on the `orbis-ps4-dump` project and write findings
to `checkpoint/docs/research/<agent_name>+v84a_link_research.md`.

---

## Context (where we are, 2026-05-13)

I'm porting Linux to PlayStation 4 Baikal hardware.  We've shipped v82,
v83, and v84a in the ethernet bring-up chain.  Every iteration has
removed a layer of mystery.  The current state has multiple wins but
link still won't reach UP.

### v82 win: SMI MDC heartbeat (kthread-based) keeps the SMI alive

v78-v81 had SMI MDC dying after ~1 minute.  v82 added a kthread that
reads BMSR via SMI C22 every 3 seconds — MDC now sustained indefinitely.

### v83 win: AN restart algorithm mirrors Orbis exactly

v83 extended the kthread to mirror `FUN_c85f0480` event 0x1: on link-down
detection, read reg 9 + 4, OR-set advertise bits, then `BMCR |= 0x1200`.
Fires every 15s while link is down.  Confirmed correct via hardware.

### v84a wins: MSI ISR + MAC engines started

v84a added (1) `pci_alloc_irq_vectors(MSI)` + stub ISR registered on
the MSI vector before BAR+0x204 IRQ block enable, (2) 4KB DMA-coherent
TX/RX descriptor rings allocated and addresses written to
BAR+0x3c/0x44 (TX) and BAR+0x40/0x48 (RX), (3) RX engine bit 0 set in
BAR+0x34 (sticky after write), TX kick fired at BAR+0x38.

Result:
- ✅ MSI vector 1 allocated, ISR registered
- ✅ `bpcie_msi_write_msg` runs for our device, `pdev->msi_enabled = true`
- ✅ RX engine bit 0 sticky in BAR+0x34 after write
- ✅ No more "call_irq_handler: No irq handler for vector" floods
- ❌ Link still DOWN (linkreg = 0x00000b18, bit 0 = 0)

### v84a critical new datapoint: bit 18 IRQ floods at 5,670 Hz

After v84a boots, IRQ 1 (our MSI vector) fires **1,360,516 times in
4 minutes** = ~5,670 Hz.

Live BAR+0x50 sampling (catching the value before the ISR W1C-acks it)
caught 11,030 samples in 2 seconds, **ALL with `irq_status = 0x00040000`
(bit 18 set)**.

The ISR W1C-acks BAR+0x50, the MAC immediately re-asserts bit 18.  Some
sticky condition keeps re-asserting bit 18 unless action beyond just
ack is taken.

Our ISR is currently a stub that only acks (no action).  Orbis's
`mts_intr` (FUN_c85edcf0) presumably does ACTION on bit 18 to clear
the underlying condition.

Note: a separate userspace experiment writing to BAR+0x54 (IRQ mask)
to try gating bit 18 crashed the kernel.  Racing with the ISR on the
mask register is bad — only ISR-side mask manipulation is safe.

## What I want from you

Use Ghidra MCP on `orbis-ps4-dump` to figure out what **bit 18 of
BAR+0x50** is, and what `mts_intr` does when it sees bit 18 set.

### Question 1 (HIGHEST priority): bit 18 semantics

Decompile `mts_intr` at `0xffffffffc85edcf0`.  The ISR walks BAR+0x50
status bits and takes per-bit actions.  Look for:

- A check like `if (status & 0x40000)` or `if (status >> 18) & 1`
- The function called or actions taken when bit 18 fires
- Does mts_intr write to other BAR registers when bit 18 fires?
- Does it read PHY registers via SMI?
- Does it kick the TX/RX engines?
- Does it clear a separate condition register that's the underlying
  source of bit 18?

### Question 2 (HIGH priority): what IS bit 18?

Look at how Orbis treats bit 18 conceptually — name string at the
nearby data section, comment, or how mts_intr's action implies the
semantics.

Hypotheses I want validated/falsified:
- (a) "PHY interrupt pending" — PHY raised SMI interrupt, MAC mirrors
  it; bit 18 clears when PHY status is read via C22
- (b) "RX engine descriptor invalid" — engine couldn't fetch a valid
  descriptor; bit 18 fires until valid descriptors loaded
- (c) "TX queue empty" — MAC wants to transmit but queue is empty;
  bit 18 fires until something is queued or TX is masked off
- (d) "MAC error / needs attention" — bit 18 is a generic error
  condition; needs investigation per other status registers
- (e) Something I haven't thought of

### Question 3 (MEDIUM priority): the BAR+0x54 mask register semantics

BAR+0x54 is the per-IRQ mask.  Orbis writes 0x7bfffe.  Bit 18 = 0 in
that mask.  Question:

- Is the mask "1 = enable" (so bit 18 = 0 means disabled)?
- Or "1 = mask out, 0 = enable" (so bit 18 = 0 means enabled)?

Empirically bit 18 IRQs are firing at 5,670 Hz on hardware, so however
Orbis programs 0x7bfffe, bit 18 must be enabled.  Either the polarity
is "0 = enable" OR Orbis programs BAR+0x54 differently than 0x7bfffe
(maybe I misread the RE notes).

### Question 4 (LOWER priority): why link still won't latch

Even after we mask out bit 18 (if that's right), what does Orbis do
between "engines started" and "link UP" that we're still missing?
Specifically:
- Does Orbis ever clear BAR+0x04 (link_status) bits via W1C, or just
  read it?
- Are there other status bits in BAR+0x50 that need to fire BEFORE
  bit 2 (link change) can fire?
- Does Orbis set a "PHY monitor enable" register somewhere?

## Constraints

- Use Ghidra MCP on `orbis-ps4-dump` (FW 12.02, base 0xffffffff_c8000000)
- Write findings to `checkpoint/docs/research/<your-name>+v84a_link_research.md`
- Be SPECIFIC: cite function addresses (FUN_cXXXXXXXX) and decompile excerpts
- Do NOT edit code; just research and write
- If you find an Orbis function that maps bit 18 → action, give exact
  pseudo-code of what the action does

## Key Ghidra anchors (from prior digs)

| Function | Address | Notes |
|---|---|---|
| `mts_intr` | `0xffffffffc85edcf0` | **PRIMARY TARGET** — bit 18 handling |
| `mts_mac_init` | `0xffffffffc85ecb60` | already replicated through "MAC ctrl bits" |
| `mts_link_change` | `0xffffffffc85eeb90` | passive BAR+0x04 reader only |
| `mts_init_rings_kick` | `0xffffffffc85ef1b0` | engine start sequence (we replicated) |
| `mts_smi_cl22_*` | (find via xref) | SMI C22 R/W primitives |

## Prior agent findings (read first to avoid duplication)

- `glm-5.1+v83_link_research.md` — gbe:phy_ctrl body, 77-step mts_mac_init
- `kimi-k2.6+v83_link_research.md` — AN restart is necessary (confirmed by v83 hardware)
- `gpt5.5+v83_link_research.md` — unconditional MMD tail writes
- `deepseek-v41+v83_link_research.md` — engine start hypothesis (falsified by v84a)

Your findings should focus on what comes AFTER engine start — what
does the ISR need to do to handle bit 18, and what does that bit
mean.
