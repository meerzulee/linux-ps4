# 2026-05-12 — Stealth-auth confirmed: SBL writes return OK but silently no-op HW

Same v3 session as the per-reg-auth doc, but probing further. The
"per-register auth" picture from `2026-05-12-sbl-p1-v3-per-reg-auth.md`
needs a sharp correction: **SBL writes to the WO control regs are
silently dropped, not actually applied.** The SAMU returns
`status=0` from the write but doesn't drive hardware.

This is **stealth auth** — protocol-level success masking effect-level
rejection — and it's a much stronger barrier than the per-register
gate we thought we saw.

---

## How we got here

Found mainline AMD's `mmGCK_SMC_IND_INDEX = 0x80` /
`mmGCK_SMC_IND_DATA = 0x81` in `asic_reg/smu/smu_7_1_1_d.h`. This is a
**second SMU access path**, independent of the SAMU/SBL mailbox, that
mainline amdgpu uses via the `RREG32_SMC` / `WREG32_SMC` macros.

Tested both paths against the same SMU register space:

| Path | Read | Write |
|---|---|---|
| **SBL mailbox** (svc `0xa404` / `0xa505`) | ✅ works for all regs | claims success but doesn't apply |
| **`mmGCK_SMC_IND`** (write idx → dword `0x80`, read/write data via dword `0x81`) | ✅ works for all regs (matches SBL reads bit-for-bit) | silently dropped |

So mainline-path reads are valuable — they give us **a verification
channel that doesn't go through SAMU**. Reading via this path shows
the true PLL/SMU state, which we can compare before/after any write
attempt.

---

## The decisive test

`CG_SPLL_FUNC_CNTL_*` (the *real* PLL state registers, RO via SBL —
`status=0xfffffff3` if you try to SBL-write them):

```
before any clock-set attempt:
  CG_SPLL_FUNC_CNTL    (0xC0500140) = 0x048e300e
  CG_SPLL_FUNC_CNTL_2  (0xC0500144) = 0x00000001
  CG_SPLL_FUNC_CNTL_3  (0xC0500148) = 0x20000000
  CG_SPLL_FUNC_CNTL_4  (0xC050014c) = 0x00800000
  CG_SPLL_FUNC_CNTL_5  (0xC0500150) = 0x00000802
```

We then ran Sony's exact `FUN_c8856160` GFX-clock-set sequence with
a **markedly different divider** (`0xAEC4`, corresponding to ~700 MHz,
which is different from the current FB_DIV byte of `0x04`):

```
SBL writes:
  WriteSmuIx(0xC05002E4, 0xAEC4)         status=0
  WriteSmuIx(0xC05002B4, 0x100)          status=0
  WriteSmuIx(0xC05002DC, 0x14009)        status=0
  WriteSmuIx(0xC05002B0, 0x19)           status=0
  WriteSmuIx(0xC05002C0, 0x08000082)     status=0
  WriteSmuIx(0xC05002C4, 0x64000000)     status=0
  WriteSmuIx(0xC05002AC, 0x60840000)     status=0
poll 0xC05002E0 for bit 2 (20 iters, both paths):
  always 0
WriteSmuIx(0xC05002AC, 0x40840000)       status=0
poll again:
  always 0

after:
  CG_SPLL_FUNC_CNTL    (0xC0500140) = 0x048e300e   ← UNCHANGED
  CG_SPLL_FUNC_CNTL_2  (0xC0500144) = 0x00000001   ← UNCHANGED
  CG_SPLL_FUNC_CNTL_3  (0xC0500148) = 0x20000000   ← UNCHANGED
  CG_SPLL_FUNC_CNTL_4  (0xC050014c) = 0x00800000   ← UNCHANGED
  CG_SPLL_FUNC_CNTL_5  (0xC0500150) = 0x00000802   ← UNCHANGED
```

The PLL state did not change. The SAMU accepted every write at the
protocol level but did not apply any of them to hardware.

---

## What it means

The auth model is **per-context, enforced by the SAMU firmware**:

- Writes from Sony's signed gbase → applied to hardware
- Writes from our PSFree/Linux context → silently no-op

The "OK" status is misleading. To detect the failure we must observe
the actual PLL state via the mainline path (or any other out-of-band
channel). The SBL response alone is not authoritative.

This is a *much* stronger barrier than a per-register gate. Even
finding all the right registers and getting auth tokens doesn't
help if the SAMU is gating on signed-context-origin of the request
itself.

---

## What the writes *do* in our context

We can think of it as: every "WriteSmuIx" from us goes into a SAMU
"audit" channel that logs and returns OK without applying. The
hardware effect is bypassed. The audit returns a clean status so
Sony's host code doesn't error-handle visibly.

This is consistent with how secure co-processors typically defend
against in-memory tampering by malicious kernel code: the protocol
remains operational, errors don't reveal the auth check, but the
effect is gated.

---

## Three things we still might try

1. **IRQ 0x98 subscription.** Sony's `sceSblDriverInitialize` registers
   an interrupt handler at vector `0x98`. Maybe the SAMU's stealth-auth
   gate is: "writes succeed only if caller is subscribed to my
   completion IRQ." This is software-fixable. Worth one rebuild+reboot
   to test.

2. **Find the non-SMU UVD bring-up path.** Maybe UVD doesn't *need*
   SMU programming after Orbis already did it at boot — maybe what
   it really needs is a specific UVD-MMIO setup sequence (not SMU
   regs) that we haven't replayed. The dungeon doc showed Sony's
   `uvd_vcpu_start_baikal` writes ~10 UVD regs that mainline doesn't
   — those may be the actual gate.

3. **Accept the limitation and document it.** Even without UVD/VCE,
   software-rendered Wayland desktop works, browser works, video
   playback works (via CPU). The 80% that's achievable is achieved.

---

## The mainline-path read trick is itself a small win

Through this dig we discovered we can read any SMU register via the
mainline `mmGCK_SMC_IND_INDEX` (dword `0x80`) / `mmGCK_SMC_IND_DATA`
(dword `0x81`) pair, no SAMU mailbox transaction needed. amdgpu's
`RREG32_SMC` macro already does this. So future work that needs to
*observe* SMU state can use the cheap path.

---

## Files

- `checkpoint/docs/research/sbl-port/2026-05-12-stealth-auth-confirmed.md` — this doc
- `checkpoint/docs/research/sbl-port/2026-05-12-sbl-p1-v3-per-reg-auth.md` — earlier wrong conclusion (kept for the per-reg observation, with this addendum as the correction)

Build artifact still ready on USB: md5 `41cf4054d226b93ad930d661950307ae`
(no kernel changes this iteration — all probing done from userspace via
`amdgpu_regs` + the v3 `ps4_sbl_smu` debugfs surface already in the
running kernel).
