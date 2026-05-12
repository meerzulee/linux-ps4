# Plan: "assume and try" — bypass the read-back verification trap

## Premise

After today's SBL Phase 1 work
(`checkpoint/docs/research/sbl-port/2026-05-12-stealth-auth-confirmed.md`)
we concluded SBL writes return `status=0` but silently no-op hardware,
based on reading `CG_SPLL_FUNC_CNTL_*` via mainline `mmGCK_SMC_IND`
before/after Sony's clock-set sequence — five PLL state registers
unchanged.

That conclusion relies on **register read-back as the truth signal**.
But the SAMU is a clever co-processor: a sophisticated stealth-auth
could filter or cache reads from our context just as easily as filter
writes. The "PLL didn't change" evidence is suggestive but not
definitive — we're measuring through a channel that SAMU may also
be controlling.

**The downstream evidence is more authoritative**: UVD VCPU's STATUS
bit 1. If our SBL writes really ARE driving HW (just invisible to
our read path), then doing Sony's exact clock-set + UVD VCPU release
sequence should make STATUS bit 1 set. If writes truly no-op, STATUS
bit 1 stays 0 (same as A17/A18 results we already have).

Either result is informative; the experiment has zero downside other
than one rebuild + one boot.

---

## Hypotheses being tested

1. **Optimistic** — SAMU applies our writes but our SBL/mainline reads
   show cached/filtered state. UVD STATUS bit 1 sets → SBL works,
   project's structural wall isn't there.
2. **Pessimistic** — SAMU genuinely drops the writes. UVD STATUS bit 1
   stays 0 → wall confirmed empirically (already strongly suggested).

---

## Concrete experiment

### Patch (against current `wip/uvd-vce-poc` HEAD)

1. **Disable A18 soft-fail** in `uvd_v4_2_hw_init` so UVD failures
   propagate (we need to OBSERVE the failure, not hide it).

2. **Add SBL writes before VCPU release** in
   `uvd_v4_2_start_liverpool` (or wherever the VCPU is unstalled).
   Replay Sony's exact `FUN_c8856160` clock-set sequence verbatim.
   Use the *current* divider value (read via mainline
   `mmGCK_SMC_IND_INDEX/DATA` at SMU reg `0xC0500140` ->
   `((CG_SPLL_FUNC_CNTL >> 24) & 0xff)` is FB_DIV; current = 0x04).
   Writing back the SAME divider should be a no-op even if applied,
   so no risk of clock corruption.

3. **Add a UVD pre-init SMU sequence too**. Even if Sony has a
   UVD-specific clock-set sequence we haven't decoded, replay the
   GFX one anyway — the act of "successfully" calling WriteSmuIx
   may be what UVD's fw is waiting for, regardless of values.

### Pseudo-code

```c
static int uvd_v4_2_start_liverpool_with_sbl(struct amdgpu_device *adev)
{
    int r;
    u32 current_cntl;

    /* 1. Read current PLL state via mainline indirect path so we know
     *    the current divider to keep things in place. */
    WREG32(mmGCK_SMC_IND_INDEX, ixCG_SPLL_FUNC_CNTL);
    current_cntl = RREG32(mmGCK_SMC_IND_DATA);
    /* divider = top byte; we use this back (no-op) so nothing breaks */

    /* 2. Replay Sony's FUN_c8856160 clock-set sequence verbatim using
     *    the current divider (so HW state is unchanged even if writes
     *    actually take effect). */
    ps4_sbl_write_smu(adev, 0xC05002E4, (current_cntl >> 24) & 0xff);
    ps4_sbl_write_smu(adev, 0xC05002B4, 0x00000100);
    ps4_sbl_write_smu(adev, 0xC05002DC, 0x00014009);
    ps4_sbl_write_smu(adev, 0xC05002B0, 0x00000019);
    ps4_sbl_write_smu(adev, 0xC05002C0, 0x08000082);
    ps4_sbl_write_smu(adev, 0xC05002C4, 0x64000000);
    ps4_sbl_write_smu(adev, 0xC05002AC, 0x60840000);
    /* poll 0xC05002E0 bit 2 set, up to 100 ms */
    /* (if SAMU is genuinely applying writes, this poll will eventually
     *  succeed; if not, it'll time out — informative either way) */
    ps4_sbl_write_smu(adev, 0xC05002AC, 0x40840000);
    /* poll again */

    /* 3. Now release VCPU as usual. */
    r = uvd_v4_2_start_liverpool_original(adev);

    /* 4. STATUS bit 1 is the downstream truth. Report whether it set. */
    DRM_INFO("ps4 uvd: SBL pre-init done; VCPU release returned %d\n", r);
    return r;
}
```

### Expected outcomes

| Outcome | Interpretation | Project impact |
|---|---|---|
| UVD STATUS bit 1 SETS, ring test passes | SBL writes ARE driving HW. Today's "stealth-auth" finding was wrong — the read-back path was the lie. | Phase 4 trivially works. Wire SBL calls into uvd_v4_2 + vce_v2_0 for real. Hardware UVD/VCE unblocked. |
| STATUS bit 1 doesn't set, but the PLL poll at `0xC05002E0` succeeds | Our writes drove some HW (the poll bit), but not enough for UVD specifically. | Need to find UVD-specific SMU registers. Ghidra dig for UVD callers of WriteSmuIx with non-GFX-clock registers. |
| Both polls timeout, STATUS bit 1 doesn't set | Stealth-auth is real for both PLL programming AND UVD. | Wall confirmed empirically. Document and park. |
| Boot panic / GPU hang | Our writes broke something unexpectedly (low chance with same-divider strategy). | Roll back to bzImage-prev (α, working desktop). |

---

## Cost

- One incremental kernel build (~2 min) — touches `uvd_v4_2.c` only,
  no headers, no Kconfig.
- One USB stage + one reboot.
- One boot capture + dmesg inspection.

Total ~10 minutes of wall time, mostly the reboot ritual.

---

## Why this hadn't been tried before

Until today's session-3 result, we thought writes returned -EACCES
universally — there was no point trying the assume-and-see approach
because the protocol-level rejection was obvious. Session 4's per-reg
auth finding then confused us into thinking we had write access where
we don't. Today's stealth-auth finding looks definitive but is only
definitive under the assumption that reads tell the truth — which
they may not.

The assume-and-try test cleanly resolves the ambiguity.

---

## Action items for the next session

- [ ] Edit `uvd_v4_2.c::uvd_v4_2_start_liverpool` to insert the SBL pre-init
      sequence before VCPU release.
- [ ] Disable A18 soft-fail in `uvd_v4_2_hw_init` (revert the patch or
      add a conditional that triggers only if the SBL pre-init fails).
- [ ] Add a build option `PS4_UVD_TRY_SBL=1` so we can toggle without
      branching kernels.
- [ ] Build, stage to USB, boot, observe.
- [ ] Document result regardless of outcome — both yes/no are
      informative.

---

## Why this is worth doing

The PS4 Linux project's biggest open question is "is the SAMU wall real
or apparent?" Today's evidence points strongly to "real" but the
evidence is indirect. A clean empirical test pinned to UVD STATUS
bit 1 gives an unambiguous answer, and the cost is one reboot.

If it works (15-25% chance by my estimation), the rest of the SBL
plan becomes straightforward and PS4 Linux gets hardware video decode.

If it doesn't, we've conclusively confirmed the wall and the project's
practical ceiling is the SW-Wayland + Hyprland-GL desktop we already
have.

Either way: a small experiment with high information content.
