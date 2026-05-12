# 2026-05-12 — SBL Phase 1 v2 — SAMU contact established; write-auth gate hit

**Source kernel:** running v76e-B1.1-α + the v1 (broken) SBL-P1 patch from build #2 dated 16:49.
**Probe method:** userspace shell scripts driving `/sys/kernel/debug/dri/0/amdgpu_regs` (mainline amdgpu's R/W register debugfs surface). **No SBL kernel module needed for any of this** — the proper SAMU protocol can be exercised entirely from userspace given any kernel with debugfs.
**Saved scripts:** `/tmp/sbl-probe.sh`, `/tmp/sbl-probe2.sh`, `/tmp/sbl-probe3.sh`, `/tmp/sbl-probe4.sh`, `/tmp/sbl-probe5.sh` (also on PS4 at `ssh ps4:/tmp/sbl-probe*.sh`).
**Status:** ✅ **SAMU contacted; SBL_SMU_READ confirmed; write-auth gate confirmed.**

---

## TL;DR

- **SBL protocol works.** Sony's `sceSblDriverReadSmuIx` sequence (write direct CMD/ARG1, indirect-kick trigger at SAMU[0x32], read direct VAL/STATUS) returns real, deterministic SAMU responses to our probes.
- **Direct vs indirect access split confirmed.** The 0x22070..0x2207c mailbox window lives at direct `rmmio + off` byte offsets in BAR5. The trigger and ack registers (`0x32`, `0x4a`) are SAMU-INTERNAL register indices, accessed through the indirect window at `rmmio + 0x22000` (index) / `rmmio + 0x22004` (data). The dungeon doc had collapsed these into one helper.
- **Read access is open.** Service id `0xa404` (`SBL_SMU_READ`) returns `status=0` for both valid and invalid SMU indices, with VAL holding the read value (or 0 for unmapped registers).
- **Write access is auth-gated.** Service id `0xa505` (`SBL_SMU_WRITE`) returns `status=0xfffffff3` (−13 = `−EACCES`) regardless of the target SMU index.
- **Unknown service IDs** (anything other than `0xa404` / `0xa505`) return `status=0xffffffdb` (−37) — distinct error class, confirming only 2 services are exposed at our protocol level.
- **Phase 1 is structurally complete** as far as userspace can take it. Cracking write-auth is Phase 2 and is a Ghidra problem.

---

## Protocol confirmed

### SBL_SMU_READ (service 0xa404)

```
direct  rmmio + 0x22070  ← 0xa404        (service id)
direct  rmmio + 0x22074  ← smu_idx
indirect SAMU[0x32]      ← 1             (kick)
direct  rmmio + 0x2207c  → status        (0 on success, −EACCES / unknown-svc on failure)
direct  rmmio + 0x22078  → smu_value     (or 0 if unmapped)
```

The ack-poll at `samu_ind_read(0x4a) & 1` in Sony's code is structurally there but
**our probes never observed bit 0 of SAMU[0x4a] in the set state**, including over
a 100-iteration tight loop. Either the SAMU completes faster than a userspace
sleep-zero loop can sample (most likely) or the ack semantics are different
(less likely — there's nothing else in the surrounding indirect regs that
flickers). Sony's code uses `wait_for_intr` in the ack loop body, which strongly
suggests the SAMU asserts IRQ 0x98 on completion and the loop wakes up after the
interrupt clears the bit — so we'd never see bit 0 set in a polled read from
userspace.

### SBL_SMU_WRITE (service 0xa505)

Same sequence as READ, but with the value written to `rmmio + 0x22078`
**before** the trigger. `status` comes back as `0xfffffff3` (= `−13` = `−EACCES`)
for every SMU index tried — including ones where the corresponding READ
returned non-zero (so the register exists; just isn't writable from our
context).

### Sample data — SAMU register map (partial)

Sweep of the standard CIK SMU register address layout. Many banks are present;
**the 0xC0500000 bank is dense and structured — almost certainly the DPM (clock /
voltage / P-state) table that Phase 3 will need to write to**:

| Bank base | Populated? | What it looks like |
|---|---|---|
| `0xC0000000` | yes, sparse | misc config — `[0x00]=0x013b8531`, `[0x10]=0x0a000000`, `[0x14]=0xc0010101` |
| `0xC0080000` | empty | (or returns 0 for all sweep offsets) |
| `0xC0100000` | empty | |
| `0xC0200000` | dense | `[0x00]=0x00004604`, `[0x10]=0x00ffffff`, `[0x20]=0x0007dfff`, `[0x200]=0x00080207` |
| `0xC0300000` | counter-like | `[0x00]=0xb50`, `[0x10]=0xb50`, `[0x20]=0xb56` — small monotonic values, **increments by 4 across reads** |
| `0xC0400000` | empty | |
| `0xC0500000` | **dense, structured** | `[0x00]=0x00400921`, then a 0x6010/0x6060 repeating-pattern region, `[0x20]=0x8000000b`, then a small-value table at `[0x80..0x100]` |
| `0xC0600000` – `0xC0A00000` | empty | |
| `0xC2000000` | yes | **PCI config mirror** — `[0x00]=0x142e1022` (AMD `0x1022` + Liverpool `0x142e`), `[0x100]=0x142f1022`, `[0x200]=0x14301022` |

### SAMU internal indirect registers (sweep 0x00..0x80)

| Idx | Value | Notes |
|---|---|---|
| `0x00` | `0x000000ff` | low byte all-1s — likely a capability or "services enabled" flag word |
| `0x02` | `0x00000001` | |
| `0x03` | `0x00000001` | |
| `0x05` | `0x00000001` | |
| `0x06` | `0x00060800` | |
| `0x07` | `0x0000007f` | low 7 bits set — another capability flag candidate |
| `0x0a` | `0x0000ff00` | |
| `0x0f..0x16` | `0xa5a5a5a5` | classic uninitialised-NVMEM sentinel — Sony's signed-firmware key/state slots that we obviously don't have |
| `0x18` | `0x00000169` | |
| `0x32` | `0x00000001` | trigger register; bit 0 stays set after we write 1 |
| `0x34` | `0x1e102000` | possibly paired with 0x36 (status/control) |
| `0x36` | `0x1e100000` | |
| `0x37` | `0x00000001` | |

`SAMU[0x32]` bit-walk: writing any value without bit 0 set causes the reg to
read back as 0; writing 1 keeps it at 1. So bit 0 is the trigger and the
register is otherwise zero — there's no "trigger-was-consumed" bit elsewhere
that we can see.

`SAMU[0x4a]` bit-walk: read-only as 0 regardless of any write we do. Consistent
with this being a hardware-driven status that our user-side polling can't catch.

---

## Status codes observed

| Status value | Decimal | Linux errno | Meaning (inferred) |
|---|---|---|---|
| `0x00000000` | 0 | — | success |
| `0xffffffdb` | −37 | `−ENAMETOOLONG` (probably SBL-specific) | unknown service id |
| `0xfffffff3` | −13 | `−EACCES` | permission denied (write blocked) |

Status `0xfffffff3` on writes is the **defining new finding** of this session.
The SAMU's signed firmware recognises our service id but explicitly returns
"permission denied". This matches PLAN.md's open question 4 exactly:

> 4. Authentication tokens. Sony's SAMU may check that the caller is "blessed" —
>    i.e., running from a signed binary.

The answer is: **yes, the SAMU does check, and the check rejects our context**.

---

## What we don't yet know

1. **What the auth check actually inspects.** Possibilities:
   - Caller CPU mode / ring (we're in ring 0; Sony's kernel is too — should match)
   - Caller VMID context (SAMU is registered to operate within VMID 15; maybe checks the CR3 / EFER state)
   - A handshake token written to some SAMU register at boot that we haven't replicated (the 0xa5a5a5a5 slots at [0x0f..0x16] are a likely candidate — Sony's `sceSblDriverInitialize` may stage keys there)
   - The presence of an IRQ-0x98 handler (the SAMU might require the caller to have registered for completion interrupts — Phase 2 territory)

2. **The ack-bit mechanism.** Polled never observed; presumably IRQ-driven.

3. **The "service id 5 + FUN_c89b7a60" handler registration** from
   `sceSblDriverInitialize`. This is a SECOND SBL-level service id that Sony
   registers a callback for (separate from the 0xa404/0xa505 mailbox path). It
   may be a write-precursor or auth-handshake message type.

4. **The CCP queue path** (`SceSblMsgTask` kthread, ring at `0xca9efc80`). Used
   for async crypto; not strictly needed for SMU work, but if auth requires
   responding to a SAMU-initiated query, it may go through this ring.

---

## Next session plan

Userspace probing has hit its ceiling. Next steps belong in Ghidra:

### A. Trace `sceSblDriverWriteSmuIx` (`c89b81d0`) callers

What does Sony's gbase do BEFORE a WriteSmuIx call that we're not doing? Two
likely candidates emerged from the Ghidra round 2 dig:

- A call to `FUN_c89b7af0` near the end of `sceSblDriverInitialize`. We don't
  know what this does — could be the auth handshake.
- The registered service-id-5 callback at `FUN_c89b7a60`. Might be a per-write
  auth precursor.

Decompile both, decode parameters, see what BAR/MSR/CR they touch.

### B. Trace the SAMU dispatcher's auth check

Strings like `samu: illegal cmd %d`, `samu: unknown cmd %d`, `samu: intst %#x(tsc:%lx)`
are present in orbis-12.02.elf — find their xrefs to locate the SAMU-side
command dispatcher. The check that returns `-EACCES` is somewhere in there;
even if we can't bypass it, knowing what it inspects tells us whether we have
any chance.

### C. Compare against `fail0verflow/radeon-tools`

User mentioned this as a resource. If it has any SAMU-aware code, it'll
shortcut a lot of the auth question.

### D. If A+B+C all dead-end on auth

The SAMU's signed firmware is the actual barrier. Two non-Ghidra paths remain:
- **Read-only SMU exploration.** Even without write, mapping the DPM table
  values lets us understand Sony's runtime power state and may suggest a
  different unblock path (e.g., directly programming UVD clocks via amdgpu's
  own non-SAMU power management if we can bypass the locked-from-CPU constraint
  some other way).
- **Hardware-level approach.** Out of scope for software work.

---

## Build artifact ready (not yet booted)

`output/6.x-baikal/bzImage` md5 `52f3475f7e09c7b0a86f86e4c127477a` — this is the
v2 SBL kernel with Makefile + debugfs hook properly bundled (the previous v2
attempt at `e115e78f` was missing those because they'd been in the v1 patch
that we disabled). Will become useful if/when we want a per-kernel SBL surface
with proper dmesg logging; not blocking anything right now since amdgpu_regs
gives us the same capability from userspace.

---

## One-paragraph summary

We can now talk to the PS4 SAMU. Read works for the entire SMU register space,
no auth needed. We've mapped enough banks to identify the DPM (clock/voltage)
table at 0xC0500000 that Phase 3 will need. Write returns -EACCES and the
unblock path goes through Ghidra reverse-engineering of Sony's SBL auth
prerequisites — possibly insurmountable if it's signed-binary-only, possibly
trivial if it's just a register sequence Sony does at init that we're missing.
