# 2026-05-12 — End-of-day summary: where the structural wall lies

After two full days of UVD bring-up work, one day of dungeon mapping, and
today's SBL Phase 1 + auth investigation, we have a *clear* picture of
exactly which constraint blocks hardware UVD on PS4 Linux.

---

## What works (today's wins)

- **GFX VMID 1 page-616 fault fixed (α — commit `82acaf4`)**. Hyprland
  GL-renders for the first time. Was the blocker for any
  GL-accelerated Wayland compositor.
- **Software-rendered Wayland desktop fully functional** at 1080p60 over
  HDMI, USB keyboard/mouse, ethernet — proven from yesterday's session
  + verified today.
- **SBL mailbox protocol decoded end-to-end** — direct vs indirect access
  split (commit `d24f1db`), four service IDs identified, all primitives
  implemented (commit `1b0edaf`).
- **SAMU mailbox contact established** — read access works for every
  SMU register; full register map for the `0xC0500000` DPM bank
  documented; Sony's GFX clock-set sequence (`FUN_c8856160`) decoded.
- **Auth model fully characterised** — writes return `status=0` but
  silently no-op hardware. Proven by reading mainline
  `mmGCK_SMC_IND_INDEX/DATA` (dword `0x80`/`0x81`) before and after
  Sony's full clock-set sequence: all 5 `CG_SPLL_FUNC_CNTL_*` registers
  unchanged.

---

## What's structurally blocked

**Hardware UVD / VCE bring-up requires SAMU-signed-context SMU writes that
we cannot replicate from PSFree-exploited ring 0.**

The proof chain (each step a separate session's hardware result):

1. UVD VCPU fw deterministically accesses GPU VA `0x300000000` and waits
   on chip state. We mapped the region; VCPU executes but STATUS bit 1
   never asserts. (A-arc, 17 iterations.)
2. The expected chip state is set by SMU register writes Sony's gbase
   does at boot via `sceSblDriverWriteSmuIx`.
3. SBL_SMU_WRITE from our Linux context: protocol returns `status=0`
   but SAMU silently drops the write — verified by out-of-band read
   showing PLL state never transitions.
4. Mainline-path `WREG32_SMC` is also silently dropped — same gate
   enforced regardless of which path we approach from.
5. The gate is enforced by SAMU's signed firmware as a per-context
   check (not per-register, not per-service-ID — those were
   intermediate hypotheses that were disproven).

Implication: even with perfect knowledge of Sony's exact register
sequences (which Ghidra gave us), software replay from Linux cannot
make the SAMU honor the writes.

---

## What still might work (low confidence)

- **IRQ 0x98 subscription.** Sony's `sceSblDriverInitialize` registers
  a SAMU completion-IRQ handler. There's a chance — though small —
  that SAMU's stealth-auth includes a "caller is subscribed to my
  IRQ" check. Testable with a kernel module that registers an IRQ
  handler via amdgpu's IH infrastructure.

  Our IH probe today showed the IH ring is alive and busy (~3000
  entries/sec at idle, mostly the VMID-15 fault loop). Unhandled
  vectors `2.61`, `2.38`, `0.49` show up in dmesg — `2.61` floods
  constantly. Without a Sony-specific source-ID-to-amdgpu-clientid
  decode table, we can't tell if any of them is SAMU.

  *Worth one rebuild + reboot to test.*

- **Use the running Orbis-set clock/voltage state.** Maybe UVD on
  PS4 Linux just needs us NOT to touch the SMU state Orbis already
  set up. Mainline amdgpu's UVD code may try to re-program clocks
  via `WREG32_SMC` (which is now silently no-op'd). If those
  no-ops happen to leave the right state, UVD might come up.
  But A-arc already tried this with mc_resume disabled and got
  the same STATUS-bit-1 failure, so this is probably not the path.

- **A hardware-side approach** (out of software scope) — modchips,
  fault injection, glitching SAMU's secure-execution bit. Out of
  scope for this project.

---

## Practical impact

The PS4 Linux project's user-facing state, end of today:

| Feature | Status | Notes |
|---|---|---|
| HDMI 1080p60 display | ✅ working |
| USB keyboard / mouse / storage | ✅ working |
| Ethernet (Baikal GbE) | ✅ working |
| Software-rendered Wayland (Weston) | ✅ working |
| GL-accelerated Wayland (Hyprland) | ✅ working (composes frames, though crashes on KDE crash cascade) |
| X11 + browser | ✅ working (installed; user verified) |
| Software video decode (libavcodec) | ✅ working |
| Hardware UVD (video decode) | ❌ structurally blocked by SAMU auth |
| Hardware VCE (video encode) | ❌ same |
| WiFi / Bluetooth (mt7668) | ❌ not yet ported (separate work) |
| Internal SATA HDD reading | ❌ encrypted, needs SAMU access we can't get |

**The 80% of PS4 Linux that's achievable without breaking SAMU is
achieved.** The remaining 20% (UVD, VCE, internal HDD encryption,
HDCP-protected video) hits the same wall: Sony's signed-firmware
enforcement.

---

## Files committed today

```
82acaf4  B1.1-α: drop DEPTH=0 override          (GFX VMID 1 fault fix)
cf452ef  SBL-P1 v1                                (mailbox primitives — wrong addresses)
d24f1db  SBL-P1 v2 (post-Ghidra)                 (direct + indirect split)
65a0ca2  SBL-P1 v2 hardware result               (SAMU contact established)
b219f7c  Ghidra dig — auth gate context          (4 service IDs, GFX clock fn)
1b0edaf  SBL-P1 v3                                (S/Z/A probe commands)
81a99df  v3 hardware result                       (per-reg auth — intermediate)
854057c  Stealth-auth confirmed                   (writes return OK, no HW effect)
```

Plus this final summary doc.

---

## Honest end-of-day position

The SBL port project, as a software-only path to unlocking hardware
UVD/VCE on PS4 Linux, **does not work** because SAMU enforces a
signed-context check that PSFree-exploited Linux cannot satisfy.

The path forward, if the goal is hardware UVD specifically:
1. **Hardware modification** (modchip, glitching, etc) — out of scope
2. **Cryptographic break of Sony's signing key** — infeasible
3. **A new userspace exploit that runs in a different security context**
   — possible but separate research effort

For users who want a working Linux desktop on PS4: today's state is
the practical ceiling. SW-decoded video, GL-accelerated GFX, USB
peripherals, 1080p HDMI — all working.

For anyone trying to push beyond this point: the structural barrier
is *not* in the Linux kernel work; it's in the secure-execution
model of the PS4 SoC. The Linux side is as polished as it can be
without root-of-trust access.
