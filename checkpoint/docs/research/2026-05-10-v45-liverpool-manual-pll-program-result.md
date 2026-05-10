# v45 — Liverpool manual PLL programming: writes silently dropped, hypothesis was wrong

Boot captured 2026-05-10 15:10. Full UART:
[`checkpoint/uart-logs/2026-05-10_1510-v45-liverpool-manual-pll-program.log`](../../uart-logs/2026-05-10_1510-v45-liverpool-manual-pll-program.log)
(186 KB, 2692 lines).

## Summary

v45 supersedes v44's preserve-BIOS-PLL short-circuit with direct PPLL
register programming. For Liverpool/Gladius in `dce_v8_0_crtc_mode_set`:
hardcode 1080p60 dividers (ref_div=1, fb_div_int=11, fb_div_frac=14,
post_div=8, targeting 148.44 MHz from 100 MHz ref), pack per the
`VGA*_PPLL_*` bit layout in `dce_8_0_sh_mask.h`, write to all four
`mmDCCG_PLL{0..3}_PLL_REF_DIV/FB_DIV/POST_DIV` register banks, dump
PRE+POST state for verification.

**Result: monitor stays dark. POST-program read shows `ref=0x0 fb=0x0
post=0x0 cntl=0x0` for all four PPLLs — IDENTICAL to PRE-program. Our
`WREG32()` calls returned without error but the registers don't store
the values.**

## What v45 actually proved

Three things, in order of importance:

**1. The mmDCCG_PLL{0..3} registers are probably NOT the actual display
PLL on Liverpool.**

Searched both 5.4-baikal (the visually-confirmed-working baseline) and
6.x-baikal source trees: NO code anywhere directly writes to
`mmDCCG_PLL[0..3]_PLL_REF_DIV/FB_DIV/POST_DIV`. The 5.4 baseline
produces full HDMI output without anyone in the kernel touching these
registers. So either ATOM SetPixelClock writes them indirectly via the
ATOM bytecode interpreter (in which case our direct writes should also
land), OR these registers are some other PLL (display clock generator,
audio PLL, redundant clock tree) and the actual pixel-clock PLL on
Liverpool lives at addresses we haven't identified.

The all-zero reads from v44/v45 are consistent with EITHER interpretation:
- "Right register, wrong access path" → writes silently dropped, reads
  always 0
- "Wrong register entirely" → reading some address whose hardware just
  ties it to ground

Without instrumenting ATOM execution, we can't distinguish these.

**2. WREG32 to DCCG block IS valid in this codebase.**

`dce_v8_0.c:1537-1539` does `WREG32(mmDCCG_AUDIO_DTO_*, ...)` — same
DCCG block, register offsets right next door (0x16b/0x16c/0x16d vs our
0x1700/0x1714/0x1728/0x173c). If the audio DTO writes work (and they
must, audio works in 5.4 setups), then `WREG32(mmDCCG_*, ...)` reaches
the hardware. Our PPLL writes were going through the right MMIO path —
the writes just don't take effect on those particular registers.

**3. amdgpu has no PLL indirect-access path.**

`RREG32_PLL`/`WREG32_PLL` are referenced in the `WREG32_PLL_P` macro at
`amdgpu.h:1370` but never #defined anywhere in amdgpu source. Compiling
`WREG32_PLL_P(...)` would error. So no AMD GPU in amdgpu's supported
list uses indirect PLL register access — meaning even if Liverpool's
PLL has special access semantics, amdgpu wouldn't have infrastructure
for it. radeon driver has `pll_rreg`/`pll_wreg` callbacks but on CIK
they're set to `radeon_invalid_rreg`/`_wreg` (only R100-era cards use
them). The "PLL needs indirect access" hypothesis is dead.

## What we already knew before this boot

Listed for completeness, no new information:

- v40 ACPI fix is independently correct (`pre-allocated IRQ 9 desc for
  ACPI SCI` fired at t=0.94s, no MTX_Tables errors all boot)
- ATOM `AdjustDisplayPll` still returns 0 even with v40 ACPI fix
  (`dce_v8_0_crtc_mode_set: ATOM returned 0, using adjusted_mode->clock=
  148500 kHz` — v28 fallback)
- `ps4_bridge_pre_enable` and `ps4_bridge_enable` both return `cq_exec=
  20` (ICC mailbox sequence executes successfully)
- Display: dark, backlight off
- HPD detection: works (`DDC: 0x194c..0x194f`, `HPD1`)

## Things I missed in earlier interpretation that the deeper log read found

| Detail | Why it matters |
|---|---|
| **ATOM BIOS string `113-Starsha2-018`** | "Starsha2" = PS4 Slim Liverpool codename. VBIOS IS present and parsed by amdgpu. Not a stub VBIOS. |
| **GPU register MMIO base = 0xE4800000, size 256 KB (BAR 5)** | Confirms our register offsets land in valid MMIO range. PPLL access SHOULD work mechanically. |
| **2nd bridge_enable takes 2.97s vs 1st takes 1.34s** | The cq_wait_set steps for DP lane status (`0x60f8`, `0x60f9`) are silently timing out on subsequent calls — no DP signal for the bridge to lock to. Direct evidence the GPU isn't outputting DP. |
| **`call_irq_handler: 2.61 No irq handler` storm with 977 suppressed** | Bridge is raising IRQs (HPD or status change) that nothing handles. Vector 0x3D on CPU 2. Worth tracing in a future iteration but not the display blocker. |
| **`amdgpu 0000:00:01.0: can't derive routing for PCI INT A: not connected`** | Expected — PS4 has no INTx routing for GPU, MSI is forced via v15 patch. |
| **`Trusted Memory Zone (TMZ) feature not supported`** | TMZ requires PSP/SMU coordination amdgpu can't establish on Liverpool. Not a display blocker. |
| **Encoder = `DFP1: INTERNAL_UNIPHY`** | UniPHY transceiver, internal to GPU. The DP TX we'd need to program to feed signal to the bridge. |

## What this means for the model

Iterating:

| Hypothesis | v44/v45 verdict |
|------|-----|
| BIOS leaves display PLL programmed across kexec | ❌ refuted (PPLL=0) |
| amdgpu must program display PLL | ✅ implied, but… |
| `mmDCCG_PLL{0..3}_*` are the display PLL | ❌ probably wrong (5.4 doesn't touch them either) |
| Direct WREG32 reaches PPLL hardware | ❌ writes don't stick on these registers |
| Need PLL_UPDATE_LOCK protocol | open (writes might be lock-gated) |
| PLL is power-gated via PLL_CNTL | open (cntl reads as 0 too) |
| Real PLL is at undiscovered registers | open (most likely given 5.4 evidence) |
| ATOM SetPixelClock works on PS4 even though AdjustDisplayPll fails | open (untested — would need to instrument ATOM) |

## Counts (vs prior iterations)

| Signal | v40 | v44 | **v45** |
|---|---|---|---|
| `pre-allocated IRQ 9` | YES | YES | **YES** |
| `MTX_Tables` failures | 0 | 0 | **0** |
| ATOM `AdjustDisplayPll returned 0` | YES | YES | **YES** |
| v28 fallback to mode->clock | YES | YES | **YES** |
| `ps4_bridge_pre_enable cq_exec=20` | YES | YES | **YES** |
| `ps4_bridge_enable cq_exec=20` | YES | YES | **YES** |
| **PPLL[0..3] PRE-program** | n/a | all 0 | **all 0** |
| **PPLL[0..3] POST-program** | n/a | n/a | **all 0 (writes dropped)** |
| **2nd bridge_enable duration** | n/a | n/a | **2.97 s (DP lane wait stalling)** |
| **`call_irq_handler: 2.61` storm** | n/a | n/a | **YES, 977 suppressed** |
| **HDMI display** | dark | dark | **dark** |

## Honest assessment of the v44/v45 path

I committed to "manual PLL programming" before verifying that
`mmDCCG_PLL_*` was actually the right register set. The earlier
multi-agent display-ideas synthesis (Opus/Hermes/GLM consensus =
ATOM IIO trace first) recommended the diagnostic-first path; I
deprioritized it in favor of "let's just try writing values" and
ended up with a result that doesn't disprove the underlying model
(the writes might be dropped because of lock OR because of wrong
register OR because of power gating, and we can't tell which from
the dump alone).

The right next step is the ATOM IIO trace that should have been
done earlier — instrument `amdgpu_atom_execute_table` so we see
exactly which registers ATOM SetPixelClock targets when it runs.
That tells us either (a) which registers we should be writing
manually if ATOM SetPixelClock fails on PS4, or (b) confirms ATOM
SetPixelClock writes them and we just need to make sure ATOM gets
called (different fix entirely).

## Possible next iterations (for the user to choose)

A. **ATOM IIO trace** — patch `atom.c` to `pr_info` every register
   read/write inside the bytecode interpreter, gated by a debug flag
   so it doesn't fire for unrelated ATOM tables. Run SetPixelClock
   and AdjustDisplayPll, see what they touch. Heaviest change but
   most informative — directly reveals the actual PLL registers and
   why AdjustDisplayPll returns 0.

B. **PLL_UPDATE_LOCK / PLL_CNTL sequence test** — keep targeting
   `mmDCCG_PLL[0..3]_*` but wrap writes with the lock/enable
   protocol (`mmDCCG_PLL{N}_PLL_UPDATE_LOCK` @ +0xc, `PLL_CNTL` @
   +0x7). If POST-program read still shows 0, "wrong register" is
   confirmed and we move to A. Cheap iteration.

C. **Read more registers** — add a wide register dump to the
   diagnostic patch (CRTC_PIXEL_RATE_CNTL, DISPCLK_DTO_CNTL,
   the SI/CIK SPLL block, the GRAPHICS_PLL, etc.) to find which
   registers are actually non-zero on PS4 and might be the real
   PLL. Diagnostic, not a fix.

D. **Look at upstream Kimi `dp_clock=0` fix angle** mentioned in
   `research/ideas/`. May be a parallel root cause for AdjustDisplayPll
   returning 0 specifically, separate from the PLL programming question.

E. **Compare 5.4 baseline UART log** — boot 5.4-baikal (which
   visually shows display), capture its UART log, look for any
   amdgpu/atom log lines that show PLL programming. Triangulate
   "what does the working kernel do that we don't".
