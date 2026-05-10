# v50 result — generic ATOM table tracer

**Date:** 2026-05-10
**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0024-amdgpu-atom-table-tracer-for-modeset-diag.patch`
**bzImage:** `output/6.x-baikal/bzImage` (md5 `5a38a4c18406085b274ba1b0edcd0a1a`)
**Boot log:** `checkpoint/uart-logs/2026-05-10_1709-v50-atom-table-tracer.log` (4301 lines, 332 KB)
**Result:** ❌ Display still dark, but the **complete ATOM master+sub table call sequence is now visible.** All tables return `ret=0`. The new failure point is one of: (a) wrong arguments to `UNIPHYTransmitterControl`, (b) wrong PIXCLK_RESYNC routing, (c) skipped DP link training pattern that the MN864729 bridge actually needs.

---

## Critical decoder discovery — `atom_table_names[]` is outdated

The kernel's `atom_table_names[]` array (in `drivers/gpu/drm/amd/include/atom-names.h`) only has **74 entries** representing an older ATOM master table layout. The actual master command table struct in `drivers/gpu/drm/amd/include/atombios.h:272+` has been reordered and extended to ~80+ entries. Several names in the trace are wrong; here's the corrected mapping (only the indices we actually saw):

| Trace prints | Real name (per `atombios.h`) |
|---|---|
| `idx=0x04 (SetClocksRatio)` | **`DIGxEncoderControl`** (deprecated alias used in BIOS internals; modern is DIG1/DIG2 at 0x4a/0x4b) |
| `idx=0x0c (SetPixelClock)` | SetPixelClock ✓ |
| `idx=0x0d (DynamicClockGating)` | EnableDispPowerGating (alias) ✓ |
| `idx=0x11 (EnableMemorySelfRefresh)` | **`AdjustDisplayPll`** |
| `idx=0x14 (ASIC_StaticPwrMgtStatusChange)` | **`SetUniphyInstance`** (alias) |
| `idx=0x21 (EnableScaler)` | EnableScaler ✓ |
| `idx=0x22 (BlankCRTC)` | BlankCRTC ✓ |
| `idx=0x23 (EnableCRTC)` | EnableCRTC ✓ |
| `idx=0x28 (SetCRTC_OverScan)` | SetCRTC_OverScan ✓ |
| `idx=0x2a (SelectCRTC_Source)` | SelectCRTC_Source ✓ |
| `idx=0x2c (UpdateCRTC_DoubleBufferRegisters)` | UpdateCRTC_DoubleBufferRegisters ✓ |
| `idx=0x31 (SetCRTC_UsingDTDTiming)` | SetCRTC_UsingDTDTiming ✓ |
| `idx=0x41 (EnableLVDS_SS)` | **`EnableSpreadSpectrumOnPPLL`** |
| `idx=0x4c (?)` | **`DIG1TransmitterControl == UNIPHYTransmitterControl`** ← THE DP TX setup table |

So when we see "trace says idx=0x4c (?) ret=0", that's actually
`UNIPHYTransmitterControl` running successfully.

---

## What runs during modeset (decoded sequence)

The second-cycle modeset (the one that matters for displaying the
desktop) runs this exact sequence between `SetPixelClock` and
`bridge_enable`:

```
[15.084] AdjustDisplayPll      (0x11) — feed it dp_clock=270000, get freq=270000
[15.084] SelectCRTC_Source     (0x2a)
[15.084] EnableDispPowerGating (0x0d)
[15.084] UpdateCRTC_DoubleBufferRegisters (0x2c)
[15.084] EnableCRTC            (0x23)  ← first
[15.084] EnableSpreadSpectrumOnPPLL (0x41)
[15.084] SetPixelClock         (0x0c) — pll=1 (PPLL2), 350µs work
[15.085] SetCRTC_UsingDTDTiming (0x31)
[15.085] SetCRTC_OverScan      (0x28)
[15.085] EnableScaler          (0x21)
[15.085] DIGxEncoderControl    (0x04) — DIG encoder setup (old-style)
[15.085] UNIPHYTransmitterControl (0x4c) — DP TX call #1
[15.085] EnableCRTC            (0x23)  ← second
[15.085] BlankCRTC             (0x22)
[15.085] DIGxEncoderControl    (0x04) — DIG encoder again
[15.085] UNIPHYTransmitterControl (0x4c) — DP TX call #2
[15.085] EnableCRTC            (0x23)  ← third
[15.085] BlankCRTC             (0x22)  ← second
[15.085] DIGxEncoderControl    (0x04) — DIG encoder again
[15.085] UNIPHYTransmitterControl (0x4c) — DP TX call #3
... bridge_pre_enable BEGIN ...
... bridge_enable BEGIN ...
[18.066] cq_exec=20 (3-second cq_wait_set hang persists)
```

**Every single ATOM table returns `ret=0`.** No errors, no aborts. The
GPU's ATOM bytecode is happy. ASIC_Init at boot also runs cleanly
through hundreds of sub-table calls.

---

## Top-level table call counts (full boot)

| Count | Table |
|---|---|
| 195 | `EnableCRTC` (0x23) — heavy use; sub-table of many ops |
| 193 | `EnableDispPowerGating` (0x0d) — also heavy sub-table use |
| 8 | `DIGxEncoderControl` (0x04) — DP TX setup sequence |
| **5** | **`UNIPHYTransmitterControl` (0x4c)** — DP transmitter actions |
| 4 | `UpdateCRTC_DoubleBufferRegisters` (0x2c) |
| 3 | `BlankCRTC` (0x22) |
| 3 | `SetPixelClock` (0x0c) — boot init + 2 modeset cycles |
| 2 | `EnableSpreadSpectrumOnPPLL` (0x41) |
| 2 | `SetCRTC_UsingDTDTiming` (0x31) |
| 2 | `SelectCRTC_Source` (0x2a) |
| 2 | `SetCRTC_OverScan` (0x28) |
| 2 | `EnableScaler` (0x21) |
| 2 | `AdjustDisplayPll` (0x11) |

Total: **1314 master+sub-table calls captured** with a single hook
in `amdgpu_atom_execute_table_locked`.

---

## What this tells us

**The full GPU-side display pipeline programming runs successfully:**

1. PPLL is programmed (SetPixelClock with pll=1, real 350µs work)
2. CRTC timing is set (SetCRTC_UsingDTDTiming)
3. Spread spectrum is configured (EnableSpreadSpectrumOnPPLL)
4. Scaler is set up (EnableScaler)
5. DIG encoder is programmed (DIGxEncoderControl ×3 — likely INIT/SETUP/ENABLE/DPVIDEOON across actions)
6. **DP transmitter is programmed (UNIPHYTransmitterControl ×3)** — INIT/SETUP/ENABLE
7. CRTC is enabled (EnableCRTC), then unblanked (BlankCRTC with `disable`)

Yet the MN864729 bridge **still doesn't see a valid DP signal** when it
polls `cq_wait_set` for lane lock — same 3-second hang as v46, v47, v48,
v49.

Three remaining hypotheses for v51:

### H1 — UNIPHYTransmitterControl is being called with wrong arguments

The trace shows `idx=0x4c ps_size=16` but we don't see the actual args
struct (action, transmitter selection, lane count, link rate, encoder
ID). Stock CIK code in `atombios_encoders.c::amdgpu_atombios_encoder_setup_dig_transmitter`
populates the args based on the encoder's properties. If PS4's encoder
properties tell ATOM to use the wrong UNIPHY block (e.g., UNIPHYA when
the bridge is actually wired to UNIPHYE), the DP signal goes to a
nonexistent or unrouted output.

**Test:** instrument `setup_dig_transmitter` and `setup_dig_encoder` to
print the action and key args before each ATOM call.

### H2 — PIXCLK_RESYNC routing isn't picking up PPLL2

The v45 register dump (when 0019/0020 was active) showed
`PIXCLK1_RESYNC_CNTL = 0x1` (others = 0). After v49 we pick `pll_id=1
(ATOM_PPLL2)`, but the routing register might still be set to whatever
BIOS-default routes PIXCLK_n to PPLL_m. If PPLL2 isn't routed to CRTC0's
pixel clock input, the CRTC fires on a dead clock line.

**Test:** read `mmPIXCLK0/1/2_RESYNC_CNTL` after `SetPixelClock` to see
if ATOM updated the routing.

### H3 — Skip-DP-link-train (patch 0006) is starving the bridge of TPS pattern

Patch 0006 makes `amdgpu_atombios_dp_link_train` early-return for
Liverpool because the kernel's clock-recovery loop fails. That bypass
also skips the **TPS1/TPS2 training-pattern phase** on the DP link.
The MN864729 bridge's `cq_wait_set` is polling MN864729-internal
registers for DP lane status that asserts only when the TX sends TPS1
or video. If we skip link training entirely *and* the encoder's
DPVIDEOON command doesn't run (or runs incorrectly), the link is
permanently in idle — no TPS, no video, no lock.

**Test:** temporarily disable patch 0006 and let the kernel's link
training run. Even if it fails, the trainer sends TPS1/TPS2 on the link
during attempts; the bridge might lock during training.

---

## v51 proposal — argue for H1 first

I'd start with **H1 (encoder/transmitter arg trace)** because it's the
cheapest, most targeted instrumentation that turns "DP TX ran" into "DP
TX ran with these specific args". H2 and H3 then become much easier to
reason about with that data.

Specific patch:
- In `atombios_encoders.c::amdgpu_atombios_encoder_setup_dig_transmitter`,
  add a print before each ATOM call showing `action`, transmitter ID,
  lane count, link rate, encoder ID, and a few key args fields.
- In `…::amdgpu_atombios_encoder_setup_dig_encoder`, similar.

If args look sane (4 lanes, 2.7 GHz, correct UNIPHY for PS4 wiring),
move to H2 (PIXCLK_RESYNC dump). If the UNIPHY selection looks wrong
(e.g., UNIPHYA when PS4 wiring is UNIPHYE), force the PS4-correct
selection.

---

## Reference paths

- This patch: `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0024-amdgpu-atom-table-tracer-for-modeset-diag.patch`
- Active: `…/0021…0023` patches (trace + floor + clobber)
- Boot log: `linux-ps4/checkpoint/uart-logs/2026-05-10_1709-v50-atom-table-tracer.log`
- v49 result: `linux-ps4/checkpoint/docs/research/2026-05-10-v49-clobber-dp-extclk-result.md`
- ATOM master table struct: `linux-ps4/src/6.x-baikal/drivers/gpu/drm/amd/include/atombios.h:272+`
- ATOM names (outdated): `linux-ps4/src/6.x-baikal/drivers/gpu/drm/amd/include/atom-names.h`
- Patch 0006 (DP link train skip): `linux-ps4/patches/6.x-baikal/0300-gpu-liverpool/0006-amdgpu-skip-dp-link-train-liverpool.patch`
