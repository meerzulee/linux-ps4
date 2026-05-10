# v44 — Liverpool preserve-BIOS-PLL: PPLL is unprogrammed at mode_set

Boot captured 2026-05-10 14:54.  Full UART:
[`checkpoint/uart-logs/2026-05-10_1454-v44-liverpool-preserve-bios-pll.log`](../../uart-logs/2026-05-10_1454-v44-liverpool-preserve-bios-pll.log)
(185 KB, 2678 lines).

## Summary

v44 supersedes the disabled v33 with a smarter Liverpool short-circuit
in `dce_v8_0_crtc_mode_set`: dump all four DCCG_PLL[0..3]_PLL_REF_DIV /
FB_DIV / POST_DIV banks plus the three PIXCLK[0..2]_RESYNC_CNTL
registers via `pr_info`, then skip every ATOM-driven mode_set call
(set_pll, set_dtd_timing, overscan_setup, scaler_setup) and only run
`do_set_base` (framebuffer scanout, direct register writes) plus
`cursor_reset`.  Hypothesis under test: PS4 boot firmware leaves the
GPU display state programmed for HDMI; if Linux/amdgpu doesn't touch it,
the bridge (MN864729 via ICC) should lock to the BIOS-default DP TX
output.

**Result: monitor stays dark.  PPLL register dump shows ALL FOUR PPLLs
hold value 0 across every register.  PIXCLK1_RESYNC_CNTL = 0x1, the
other two = 0.**  This refutes the BIOS-preserves-display-state
hypothesis.  The display PLL is genuinely unprogrammed at the moment
mode_set runs — there is no BIOS state to "preserve".

## What the dump shows

```
amdgpu: dce_v8_0_crtc_mode_set: ATOM returned 0, using adjusted_mode->clock=148500 kHz
amdgpu: dce_v8_0_crtc_mode_set: Liverpool PPLL0 (BIOS): ref=0x00000000 fb=0x00000000 post=0x00000000
amdgpu: dce_v8_0_crtc_mode_set: Liverpool PPLL1 (BIOS): ref=0x00000000 fb=0x00000000 post=0x00000000
amdgpu: dce_v8_0_crtc_mode_set: Liverpool PPLL2 (BIOS): ref=0x00000000 fb=0x00000000 post=0x00000000
amdgpu: dce_v8_0_crtc_mode_set: Liverpool PPLL3 (BIOS): ref=0x00000000 fb=0x00000000 post=0x00000000
amdgpu: dce_v8_0_crtc_mode_set: Liverpool PIXCLK0/1/2 RESYNC: 0x00000000 0x00000001 0x00000000
amdgpu: dce_v8_0_crtc_mode_set: Liverpool - preserving BIOS PLL/timing,
            framebuffer-only setup (clock=148500 kHz, x=0, y=0)
```

Notes:
- `PIXCLK1_RESYNC_CNTL = 0x1` is non-zero, so we ARE successfully
  reading these MMIO offsets — the zero values for PPLL banks are real,
  not a register-access bug.
- ATOM `AdjustDisplayPll` is still returning 0 even with v40 ACPI fix
  active (`pre-allocated IRQ 9 desc for ACPI SCI` fired at t=0.94s).
  v28 fallback to `adjusted_mode->clock = 148500 kHz` works.
- All 8 calls to `ps4_bridge_pre_enable` / `ps4_bridge_enable` succeed
  with `cq_exec=20` (success).  The bridge is being driven correctly;
  it just has no signal to lock to from the GPU side.

## What this means for our model of the PS4 display path

Previous mental model (now refuted):

> PS4 firmware boots HDMI for the PS4 OS UI → kexec into Linux → GPU
> display state is left intact → if Linux doesn't touch it, the bridge
> stays locked to the BIOS-default scanout.

Actual state on the kexec path:

> PS4 firmware programs HDMI for PS4 OS → ArabPixel payload runs and
> kexecs into Linux → display PLL gets reset to zero somewhere in that
> handoff → Linux/amdgpu must reprogram the PLL itself, but ATOM
> AdjustDisplayPll/SetPixelClock can't help (PS4 VBIOS lacks usable
> table data).

The "somewhere in that handoff" is most likely the kexec itself —
loading a new kernel image probably resets the display engine's clock
tree even if it doesn't touch the framebuffer scanout.  PS4-OS's own
display state is gone before our kernel runs its first instruction.

This also kills three weaker fallback hypotheses:
- "Maybe amdgpu's earlier hw_init programs PLL via ATOM and we don't
  see it" — no, PPLL is still zero by the time mode_set runs; either
  hw_init never tried, or its ATOM call was just as broken.
- "Maybe PIXCLK_RESYNC routing is the problem" — the routing register
  reads correctly (PIXCLK1 = 0x1 selecting PPLL1 for CRTC1), but PPLL1
  itself has all-zero dividers.
- "Maybe v33's skip path stays valid; just need to keep ATOM out of
  the way" — no, skipping ATOM = skipping the only thing that could
  have programmed the PLL on this kernel.

## Why earlier dark-screen iterations also failed

Re-reading prior iteration results through the PPLL-is-zero lens:

| Iter | PLL programming behaviour | Result |
|------|---------------------------|--------|
| v33 (skip ATOM PLL) | nobody programs PLL | dark — expected, PPLL never written |
| v42 (let ATOM run with v40 ACPI fix) | ATOM SetPixelClock called but unverified whether it programmed anything | dark — likely ATOM SetPixelClock is broken too |
| v44 (preserve BIOS state) | nobody programs PLL | dark — same as v33 mechanically |

The common thread: **none of these iterations actually programmed the
display PLL with valid dividers**.  Whether ATOM SetPixelClock writes
anything on PS4 is now the open question — answering it requires a
specific test (run set_pll + dump PPLL after) that we haven't done.

## Counts (vs prior iterations)

| Signal | v32 | v40 | v43 | **v44** |
|---|---|---|---|---|
| Linux version | 1 | 1 | 1 | 1 |
| `pre-allocated IRQ 9` | n/a | YES | YES | **YES** |
| `MTX_Tables` failures | many | 0 | 0 | **0** |
| ATOM `AdjustDisplayPll returned 0` | YES | YES | YES | **YES** |
| `ATOM returned 0, using adjusted_mode->clock` (v28 fallback) | YES | YES | YES | **YES** |
| `ps4_bridge_pre_enable` cq_exec=20 | YES | YES | YES | **YES** |
| `ps4_bridge_enable` cq_exec=20 | YES | YES | YES | **YES** |
| **PPLL[0..3] register state** | unknown | unknown | unknown | **all zeros** |
| **HDMI display** | dark | dark | dark | **dark** |

## What v44 DID prove

- **Direct register access works.**  PIXCLK1_RESYNC_CNTL reads as 1, so
  the MMIO path to DCE registers is functional.  Future patches can
  WRITE these registers with confidence.
- **PPLL state is the actual missing piece.**  Not a downstream encoder
  or bridge issue — the bridge sees nothing to lock onto because the
  GPU has no pixel clock at all.
- **v40 ACPI fix is independently correct.**  No regression on the ACPI
  signals; mutex chain stays healthy throughout boot.

## Next iteration (v45)

Per user direction: write a manual PLL programmer for Liverpool.

Target mode: 1920x1080 @ 60 Hz progressive = 148.5 MHz pixel clock.

CIK display PLL register layout from `dce_8_0_d.h`:
- `mmDCCG_PLL{0..3}_PLL_REF_DIV` @ 0x1700 + 0x14*N
- `mmDCCG_PLL{0..3}_PLL_FB_DIV`  @ 0x1701 + 0x14*N
- `mmDCCG_PLL{0..3}_PLL_POST_DIV` @ 0x1702 + 0x14*N

PIXCLK1_RESYNC_CNTL = 0x1 indicates PPLL1 is the display-PLL the BIOS
intended (or that amdgpu/connector-routing chose) for CRTC1.  v45 will
target PPLL1 by default.  Standard avivo PLL math for 100 MHz reference
clock and 148.5 MHz pixel clock target: pick post_div=8, fb_div=11.88
(11 + 57672/65536 fractional), ref_div=1, giving VCO=1188 MHz.

If v45 lights up the display: confirmed root cause was lack of PLL
programming.  If it stays dark but PPLL bits read back as the values we
wrote: PLL is programmed but downstream (DP TX, DIG encoder) is broken
and needs separate fix.  If PLL bits don't read back what we wrote: the
register layout assumption is wrong and we need to consult radeon's
CIK helper for reference.
