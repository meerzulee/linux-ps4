# 2026-05-12 — SBL Phase 1 v3 hardware result: auth is per-register, not global

**Kernel:** v3 build, md5 `41cf4054d226b93ad930d661950307ae` (built 16:55, booted fresh ~17:54).
**Boot log:** `checkpoint/uart-logs/2026-05-12_1754-sbl-p1-v3-auth-probes.log`
**Probe surface:** `/sys/kernel/debug/dri/0/ps4_sbl_smu` with v3's expanded command set (R/W/S/Z/A + P/I/X/Y).

---

## Headline

The earlier conclusion ("auth is a global gate that blocks all writes") was
**wrong**. Writes are gated **per register**. The SAMU firmware permits writes
to designated control-input registers (the PLL programming pipeline at
`0xC05002xx`) and rejects writes to status/identity registers.

This means we already have the access we need to program SMU control regs —
the question now is whether our writes drive hardware, since the control-
input registers read back as 0 (suggesting they're write-only data slots).

---

## Probe results table

| Register | Read (before) | Write status | Read (after) | Interpretation |
|---|---|---|---|---|
| `0xC05002E4` (PLL divider data) | `0x00000000` | **`0x00000000`** (OK) | `0x00000000` | WO control input |
| `0xC05002B0/B4/DC/C0/C4/AC` (PLL ctrl seq) | `0x00000000` | **`0x00000000`** (OK) | `0x00000000` | WO control inputs |
| `0xC0500000` (PLL status) | `0x00400921` | **`0xfffffff3`** −EACCES | `0x00400921` unchanged | RO, write rejected |
| `0xC2000000` (chip identity) | `0x142e1022` | **`0xfffffff3`** −EACCES | `0x142e1022` unchanged | RO, write rejected |
| `0xC05002E0` (PLL ready poll) | `0x00000000` | (not written) | `0x00000000` after full Sony seq | Did NOT show bit 2 set |

Service IDs `0xa202` and `0xa303` still return `0xffffffdb` (unknown service)
on this fresh boot — so those service IDs *are* known to the SAMU but
require some setup we don't do (most likely Sony's `sceSblDriverInitialize`
populates SAMU state slots that mark them valid).

---

## What changed since session 3

Session 3 (commit `65a0ca2`) showed *every* `0xa505` write attempt returning
`-EACCES`, leading us to believe writes were globally blocked. This session,
on a fresh boot of the v3 kernel, the baseline write returned status=0 for
PLL control regs. Difference is:

- **Fresh boot** — the prior session's experimentation had left SAMU in some
  state that may have triggered a global lockdown (e.g., one of our many
  random writes to `BAR5+0x32` directly in v1 might have hit a SAMU
  "self-defense" bit).
- **OR** the v2 kernel had something running that touched SAMU and our
  writes interleaved with it — also plausible.

Either way: **the per-register auth model is the true behaviour**. On a
fresh boot:
- All reads succeed (status=0)
- Writes to RO regs (`0xC0500000`, `0xC2000000`) fail with -EACCES
- Writes to WO PLL control regs (`0xC05002xx`) return OK

---

## Full Sony GFX clock-set sequence — replayed but no observable PLL toggle

We replayed `FUN_c8856160` exactly: 7 writes + first poll on `0xC05002E0`
bit 2, then PLL release toggle, then second poll. Both polls stayed at 0
across 10 iterations.

Two interpretations:

1. **No-op:** the current GFX clock divider happens to equal what we wrote
   (or close enough that no PLL retransition is needed). Sony's host-side
   code has this same optimisation: `if (divider == cached) return;`. The
   SAMU may have the same idle-on-no-change.
2. **Writes accepted but ignored:** the SAMU acknowledges the protocol
   (returns status=0) but doesn't actually apply because some precondition
   isn't met. Possible precondition candidates: PLL must be in a specific
   state before reprogramming; or the workspace-context dispatch is
   required (which our `Z` doesn't fully replicate).

To distinguish (1) vs (2) without rebooting, we'd want to:
- Read GFX clock state through a **non-SMU path** (e.g., mainline amdgpu's
  `mmCG_SPLL_FUNC_CNTL`, dword index `0xc0`, byte offset `0x300` in rmmio)
  before/after our writes
- Or try writing a markedly different divider that should force a transition
- Or write specifically to PG (power-gating) control regs and see if a
  block's clock-on bit visibly changes

---

## What we did NOT make progress on

- **`0xa202` / `0xa303` services** — still rejected as unknown. Whatever
  setup unlocks them isn't `Z` (workspace pointer) or `A` (completion ack).
  Likely a SAMU-direct command channel sequence Sony does very early at boot
  that we haven't found yet (could be in `FUN_c89b64f0`, the
  "pre-init" stub called at the start of `sceSblDriverInitialize`).
- **Verifying writes drive HW** — control regs read as 0 regardless of what
  we wrote, so we can't confirm round-trip via SMU alone. Need a parallel
  observation channel.

---

## Status of the SBL port project after today

- **SBL Phase 1 (mailbox primitives + probes): COMPLETE**
- **SBL Phase 1 auth question: ANSWERED** — per-register auth, control regs
  are writable, status/identity regs are RO. The block we worried about isn't
  the structural blocker we thought; it's normal RO/WO partitioning enforced
  by the SAMU firmware.
- **SBL Phase 2 (IRQ 0x98 handler + workspace BO): not yet attempted**
- **SBL Phase 3 (Linux side calling WriteSmuIx for clock-set): one Ghidra
  task away** — need to find Sony's UVD-specific clock-set sequence (likely
  in a function we haven't decompiled yet)
- **SBL Phase 4 (wire amdgpu's uvd_v4_2_hw_init to call our primitives):
  ready as soon as Phase 3 yields the value table**

---

## Next iteration plan

1. **Decompile `FUN_c8855a30` (heavy WriteSmuIx caller, 6+ writes per call)**
   — likely the full P-state or PG setup table. Extract the SMU register/value
   pairs.
2. **Decompile `FUN_c8857020` (4 WriteSmuIx calls per invocation)** —
   probably a P-state index set.
3. **Find UVD-specific clock writes** — search for WriteSmuIx callers in
   functions whose names or string-xrefs mention UVD / video.
4. **Verify HW effect of our writes** — write a divider corresponding to a
   markedly different GFX clock (e.g. 400 MHz vs the current
   ~600 MHz/800 MHz default), then read mainline `mmCG_SPLL_FUNC_CNTL` (dword
   index `0xc0`) via amdgpu_regs to see if the FB_DIV / REF_DIV fields
   actually changed.
5. **If time: probe the SAMU-direct command sequence used in `FUN_c89b64f0`**
   to unlock `0xa202` / `0xa303` services. May reveal additional SBL ops.
