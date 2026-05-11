# UVD bring-up master map

**Single, in-place-updated document tracking every UVD iteration.**
Each new iteration appends to the ladder; the "current state" + "decision
tree" sections get rewritten in place.

---

## Where we are NOW (updated 2026-05-11 23:00, after A7-revert)

**Last result: A7-revert** (commit `c7650f3` + series-disabled 0047,
build `0c895f27...`).
- ✅ Cache sync restored — reaches Sony's `0x3f7f` pattern at some
  point in the 2-sec window (timing varies per boot)
- ❌ STATUS bit 1 still doesn't fire

**Sampling jitter observation**: across A5/A6/A7-revert the cache
reaches `0x3f7f` at different sample slots (t=1200 / t=800-1200 /
t=400). That's our 400ms sampling under-resolving a transient event,
not a real behavior difference. **Real signal: cache reaches synced
state once within the 2-sec poll, then drops back.**

**Side experiment done**: test-baikal kernel was tested at 22:53 —
slice in `checkpoint/uart-logs/2026-05-11_2253-test-baikal.log` (6667
lines — significant — review pending).

**One-line state:** All structural memory mapping fixed. VCPU is
alive, executes microcode, cache reaches synced. Microcode never
asserts STATUS bit 1. We've confirmed firmware reads region 2/3
content (A7 regression proved it).

**Next move candidates** (cheap first):
- **A7c**: write **actual region SIZES** at region 2[0]/3[0]
  (`0x124000`/`0x4000`) — addresses the "those slots are size fields"
  hypothesis with real values
- **A9**: change `k` clock divider (4 → 1, 8, or 15)
- **Review test-baikal log** — may reveal what a different kernel
  does differently with the same hardware

---

## Where we are NOW (updated 2026-05-11 23:30, after A9)

**Last result: A9 (10s poll)** — ❌ **time is NOT the gate**.
- 10 sec STATUS poll, 10 samples at 1-sec intervals
- STATUS=0x4 the entire 10 sec; bit 1 never sets
- Cache cycle visible: synced (0x3f7f) at t=1000 and t=6000, ~5 sec apart
- Steady-state loop — fw periodically fills+syncs cache, drops back, repeats

**Fully ruled out**: VCPU isn't slow-starting. Microcode is in a
deliberate wait loop, expecting some specific event/signal we don't
provide.

**Tested and ruled out (2026-05-11 23:35):**
- **A10**: ❌ Sony doesn't WRITE mmUVD_SCRATCH — only reads for
  diagnostics. No "host_ready" magic in SCRATCH.
- **A12**: ❌ No post-start function. Sony's IOCTL handler calls
  start_dispatch then immediately sets state=2. No vcpu_kick.
- **A13**: ⏸️ Requires VCPU ISA disassembler (Cadence/Tensilica) to
  search the firmware microcode itself. Not tractable without
  tooling.

**Remaining candidates** (in order of cheapness/info-value):
- **A15**: Try other non-1 magic values at region 2[0]/3[0] —
  e.g., 0x80000000, Sony's IOCTL constant 0x300308000 (user buffer
  start), or self-referencing pointers (region 2/3 start VA).
- **A16**: Examine SBL/ICC commands Sony might issue around UVD init —
  Ghidra-only.
- **B1** (deeper): per-vmid PD allocation mimicking Sony's gbase.

**Things ruled out as the gate:**
- ❌ Range / GART size / PT walk structure (resolved by A-arc)
- ❌ Read/write permissions (resolved)
- ❌ Region 2/3 mapping (A4)
- ❌ UDEC tile config (A6 — partial fix, not gate)
- ❌ Clock-write order (A6)
- ❌ Magic flag `1` at region 2/3[0] (A7 regression)
- ❌ Magic SIZE at region 2/3[0] (A8 — neutral)
- ❌ Time (A9 — 10s)
- ❌ mc_resume hidden effects (A14)
- ❌ Clock divider (A11 — confirmed k is divider, but no value helps)
- ❌ SCRATCH register writes (A10 — Sony only reads)
- ❌ Post-start kick function (A12 — doesn't exist)

**Strategic pivot (deferred per user)**: graceful-fail amdgpu so DRM
comes up without UVD. Available if/when we exhaust UVD options.

---

## The goal

What "UVD done" looks like:
- `[drm] UVD initialized successfully` in dmesg
- `STATUS bit 1` (= 0x2) set within the 2-sec timeout in `uvd_v4_2_start_liverpool`
- Ring test passes (`amdgpu_ring_test_helper` returns 0)
- `hw_init of IP block <uvd_v4_2>` succeeds, amdgpu probe completes
- `/dev/dri/card0` appears (we get a real DRM device)
- `vainfo` reports working UVD decoders

After that, **VCE bring-up** is the next domino (mirrors UVD structurally).

---

## Iteration ladder

Numbered chronologically. Each row = one boot test.

| # | Tag | Hypothesis tested | Patch # | Result | UART log |
|---|---|---|---|---|---|
| v73 | LMI base writes | VBASE writes change fault page | (early) | 🟡 fault page moved | (pre-v76 era) |
| v74 | Mainline mc_resume early | LMI ext regs may matter | 0034 | 🟡 fault page settled at 0x300000 | 2026-05-11-v74 |
| v75 | UVD BO size 2.7 MB → 3.5 MB | BO might be too small | 0035 | ❌ no change | 2026-05-11-v75 |
| v76a | Remove spurious 0x3d62/63 + fix 0x3da9 + VBASE=0 | Ghidra-derived register fixes | 0036 | ❌ no change | 2026-05-11_1855 |
| v76b | LMI_ADDR_EXT/EXT40_ADDR = 0 | Match Sony's post-reset state | 0037 | ❌ no change | 2026-05-11_2008 |
| v76d-α | VC[1..15]_END_ADDR widened to 32 GB | Range protection | 0038 | ❌ no change — **ruled out range** | 2026-05-11_2008-v76d-extend-vmid-range |
| v76d-β-1 | GART 512 MB → 16 GB | GART boundary | 0039 | ❌ no change — **ruled out boundary** | 2026-05-11_2025-v76d-beta1-gart-16gb |
| v76d-β-2-A | Override VC1_CNTL DEPTH=0 + dummy bind at 0x300000000 | PT walk fail from flat-GART-as-PD | 0040 | 🟢 **fault MOVED** to VA 0, UVD client → fw is alive | 2026-05-11_2051-v76d-beta2-option-a |
| v76d-β-2-A1.5 | + dummy bind at GART VA 0 | Catch the null-deref | 0041 | 🟢 **faults GONE** (silent stall) | 2026-05-11_2109-v76d-beta2-a15-bind-va0 |
| v76d-β-2-A2 | 1920 KB GTT BO with real fw bytes at 0x300000000 | Replace dummy zeros with real microcode | 0042 | 🟢 fw EXECUTING (write fault) | 2026-05-11_2124-v76d-beta2-a2-fw-mirror |
| v76d-β-2-A3 | + AMDGPU_PTE_WRITEABLE | Allow fw to write its own region | 0043 | 🟢 zero faults; silent stall (STATUS=0x4) | 2026-05-11_2132-v76d-beta2-a3-writeable |
| v76d-β-2-A4 | Mirror extended to 3.1 MB (regions 1+2+3) | Region 2/3 might be needed | 0044 | ❌ no change — **regions 2/3 not needed for init** | 2026-05-11_2143-v76d-beta2-a4-all-3-regions |
| v76d-β-2-A5 | Sample 10 VCPU regs every 400ms during STATUS poll | Diagnostic — what is fw doing? | 0045 | 🟢 0x3d67 cycles 0x196f↔0x3f7f (cache fills); only 0x3d67 changes | 2026-05-11_2157-v76d-beta2-a5-instrument |
| v76d-β-2-A6 | Drop mc_resume + reorder 0x3bd3/4/5 to 4-5-3 | Code-review-found divergences | 0046 | 🟢 cache reaches synced state earlier (t=800 vs t=1200) & sustains | 2026-05-11_2210-v76d-beta2-a6-skip-mc-resume |
| v76d-β-2-A7 | Write `0x1` at region 2[0] + region 3[0] | fw polls msgq[0] for "host ready"? | 0047 | ❌ **REGRESSION** — cache no longer reaches 0x3f7f. fw reads those slots; expects ≠ 1 | 2026-05-11_2221-v76d-beta2-a7-msgq-magic |
| (interlude) | test-baikal kernel + our initramfs (no UVD patches) | sanity check different kernel | — | 6667-line log, review pending | 2026-05-11_2253-test-baikal |
| v76d-β-2-A7-revert | Disable 0047 in series | Restore A6 cache-sync behavior | (series only) | ✅ cache `0x3f7f` returns at t=400ms; STATUS still 0x4 | 2026-05-11_2257-v76d-beta2-a7-revert |
| v76d-β-2-A8 | Combined: write region 2/3 SIZES (0x124000/0x4000) at slot 0 + k clock divider 4→1 | A7c (size fields) + A9 (fastest clock) | 0048 | 🟡 sizes neutral (no regression like A7's `1`); cache now reaches synced TWICE (t=400 + t=1600) instead of once. STATUS still 0x4. **Did NOT hurt; faster cache cycling consistent with k=1.** Bonus: user observed "white screen before /init" — first HDMI signal across iterations, but no `/dev/fb*` exists so panel is just sitting at bridge's last config (not Linux fbcon) | 2026-05-11_2310-v76d-beta2-a8-sizes-k1 |
| v76d-β-2-A9 | Extend STATUS poll 2s → 10s, sample every 1s (10 samples) | If fw needs more startup time, longer wait reveals; else rules out "needs more time" | 0049 | ❌ **Time NOT the gate.** 10s → STATUS still 0x4. Cache cycles ~5 sec (synced at t=1000, t=6000). Steady-state loop. | 2026-05-11_2326-v76d-beta2-a9-10sec-poll |
| v76d-β-2-A14+A11 | Re-enable mc_resume (skip 3 UDEC writes) + k clock 1→15 | A14: hidden mc_resume side effects? A11: k=15 should slow cache cycle ~15x if k is pure clock divider | 0050 | 🟡 **k IS a clock divider** (confirmed): k=15 cache sync at t=0 only (>10s cycle). A14: no observable effect. STATUS still 0x4. | 2026-05-11_2342-v76d-beta2-a14-a11-mcresume-k15 |

**Legend:** ❌ no change, 🟡 some change but not the gate, 🟢 progress

---

## Things ruled out

Each is a hypothesis we tested and definitively eliminated:

1. **Range protection** (v76d-α) — extending VC4 range to 32 GB didn't change anything
2. **GART boundary** (v76d-β-1) — 16 GB GART didn't change anything
3. **PT walk structure** (v76d-β-2-A FIXED) — flat-walk + bind 0x300000000 unblocked it
4. **Read permissions** (v76d-β-2-A2 FIXED) — real fw bytes
5. **Write permissions** (v76d-β-2-A3 FIXED) — PTE_WRITEABLE
6. **Region 2/3 mapping** (v76d-β-2-A4) — mapping them changes nothing
7. **mc_resume UDEC config** (v76d-β-2-A6 PARTIAL FIX) — real divergence, improves cache, not the gate
8. **Clock-enable order** (v76d-β-2-A6) — Sony's 4-5-3 order applied
9. **Magic `0x00000001` at region 2[0]/3[0]** (v76d-β-2-A7) — REGRESSION; fw reads those slots
   and expects something other than `1`. Likely they're SIZE fields, not flags.

---

## Decision tree of remaining hypotheses

### Currently being tested
- **A7-revert**: disable 0047 patch — confirm we get back to A6 behavior

### Cheapest next iterations (post-revert)

- **A7c**: write **actual region sizes** at the start of region 2/3 —
  i.e., `*region2 = 0x124000` (region 2 size in bytes) and
  `*region3 = 0x4000` (region 3 size). Better-grounded than A7's
  arbitrary `1`. If those slots are SIZE fields, writing the correct
  size unblocks fw.
- **A9**: change `k` (clock divider used in 0x3d3c, subreg 0x99/9a/162,
  0x3da3, 0x3da1) from 4 to other values — try 1 (fastest), 8, 15
- **A7b**: write magic at OTHER offsets (e.g., region 1 end, msgq[max-1])
- **A8**: try `liverpool_uvd_rev0.bin` or `liverpool_uvd_gladius.bin`
  instead — unlikely (Baikal silicon needs rev 1) but cheap to test

### Moderate effort

- **A10**: SMU UVD power-on sequence — Sony's bring-up might be preceded by an SMU command we don't issue. Look at sbl_send_command (0xa5 etc.) calls right before Sony's start_baikal.
- **A11**: Look for what (else) writes to UVD_STATUS bit 1 — search Sony's binary for any write to 0x3daf with bit 1 set. If found, that path tells us what hardware/software is supposed to set it.
- **A12**: ICC interrupt path — Sony's UVD has IRQ 0x7c. We have AMDGPU_IRQ_CLIENTID_LEGACY irq 124 set up but maybe the wrong destination on Baikal.

### Bigger structural

- **B1**: Per-VMID page directory (mimicking Sony's gbase_create_vmid). Currently we use DEPTH=0 flat walk; Sony uses DEPTH=1 with proper per-vmid PD. If the firmware microcode does VMID-aware reads expecting 2-level walk behavior, we'd need to allocate real per-vmid PDs.
- **B2**: Different VMID than 4. Sony's KMD allocates VMID dynamically; maybe the FIRST process gets VMID 1 (which is the kernel-special 64 GB VA slot per dungeon map). Try with VMID 1 instead.
- **B3**: ATOM BIOS UVD setup. Sony might run an ATOM table for UVD init that mainline doesn't trigger. Look at our ATOM table tracer for UVD-related calls.

### Dead ends to avoid
- ❌ Larger BO size beyond 3.1 MB (covered by A4)
- ❌ Range-protection tuning (covered by α)
- ❌ Changing PAGE_TABLE_DEPTH back to 1 (would regress to PT walk fail)

---

## Current code state

What our amdgpu UVD bring-up does, post-A7:

```
gmc_v7_0_gart_enable (patched):
  - GART size = 16 GB
  - VC[1..15]_END_ADDR = 32 GB - 1 page (v76d-α)
  - VC1_CNTL PAGE_TABLE_DEPTH = 0 (v76d-β-2-A)
  - amdgpu_gart_bind dummy at GART 0x0 + 0x300000000 (R/W flags)

uvd_v4_2_setup_fw_mirror_liverpool (new helper):
  - Allocate 3.1 MB GTT BO
  - memcpy fw into start of region 1
  - WRITE 0x00000001 at region 2[0] and region 3[0]    ← A7
  - amdgpu_gart_bind at 0x300000000 (overwrites dummy, R/W flags)

uvd_v4_2_start_liverpool:
  - Skip uvd_v4_2_mc_resume   ← A6
  - Sony's clock-write order  ← A6
  - All Sony's Baikal-specific register writes (matched)
  - Skip ctx[+0x40]/CACHE_VMID = 4 (hardcoded)
  - 2-sec STATUS poll with 10-register sample table  ← A5
  - On success: 0x3d40 |= 2, clear STATUS bit 2, set 0x9e0, 0x501 = 3
```

---

## Key register values (current observed end-state)

From A6 final dmesg:
```
STATUS=0x00000004        (bit 2 = "init busy" still set)
SOFT_RESET=0x00000000    (all reset bits clear — VCPU released)
LMI_STATUS=0x00000004    (same as STATUS)
LMI_VM_VBASE_HI=0        (matches Sony)
LMI_VM_VBASE_LO=0        (matches Sony)
LMI_EXT40_ADDR=0         (matches Sony, v76b)
```

From A6 sample table:
```
  ms |  STATUS  | 0x3d67  | 0x3d42  | 0x3d40  | 0x3d3d  | 0x3d98  | 0x3da0  | 0x3bc6  | 0x3e41  | 0x3d45
   0 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
 400 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
 800 |00000004 |00003f7f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000  ← synced
1200 |00000004 |00003f7f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000  ← still synced
1600 |00000004 |0000196f |00000000 |00000000 |003e0030 |0ff20200 |00000000 |00000000 |00000000 |00000000
```

Diff to look for in A7's table: any register beyond 0x3d67 changing,
or 0x3d67 reaching new patterns, or STATUS bit 1 setting.

---

## Reference: Sony's Baikal layout (Ghidra-derived)

UVD memory regions in vmid 4:
- **Region 1** 0x300000000..0x3001E0000 (1920 KB) — firmware target + save/restore
- **Region 2** 0x3001E0000..0x300304000 (1168 KB) — heap / IB stage
- **Region 3** 0x300304000..0x300308000 (16 KB) — message queue

Region totals: 0x308000 = 3.1 MB (matches Sony's `uvd_kmd_hw_init_stage2` exactly)

Sony's `uvd_vcpu_start_baikal` (FUN_c88f8610) writes ~70 registers in
sequence. Our `uvd_v4_2_start_liverpool` matches them all (A6 confirmed
the previous divergences are gone).

VCPU clock divider (Sony's `ctx[+0x40] & 0xf`): we use `k = 4`. Unknown
if this matches what Sony's KMD passes for our chip rev. Candidate
for A9 if A7 fails.

Firmware loaded: `liverpool_uvd_baikal.bin` (rev 1, 313912 bytes,
banner `[ATI LIB=UVDFW,1.101.42]`).

---

## How to use this document

**Before each iteration:**
- Read "Where we are NOW" + "Decision tree"
- Pick the next hypothesis from the decision tree
- Note the chosen tag (Ax / Bx)

**After each boot test:**
- Update "Where we are NOW"
- Append a row to "Iteration ladder"
- Move ruled-out items to "Things ruled out"
- Update "Decision tree" — remove tested branches, possibly add new ones
- Update "Current code state" if patches changed
- Update "Key register values" if dmesg shows new patterns

**Keeping the doc honest:**
- Don't list speculative future work in the ladder — only actual tests
- Mark dead ends explicitly
- Cite UART log filename for every row

---

## Workflow improvements queued (do these once UVD is done)

These don't affect UVD bring-up but cut friction once we resume normal
development. Discussed 2026-05-11 ~23:10, deferred until UVD is closed.

1. **`scripts/scp-bzimage.sh`** — mirror of `swap-bzimage.sh` but via
   SSH (USB stays in PS4):
   ```
   ssh ps4 sudo mkdir -p /mnt/ps4boot
   ssh ps4 sudo mount /dev/sda1 /mnt/ps4boot
   scp output/6.x-baikal/bzImage ps4:/mnt/ps4boot/bzImage
   ssh ps4 'sudo sync && sudo umount /mnt/ps4boot'
   ```
   Faster than the physical-swap cycle (which is ~30 sec each way and
   wears the USB connector). Falls back to physical only if PS4 won't
   boot to SSH.

2. **Auto-mount USB FAT32 on PS4** — add to PS4's `/etc/fstab`:
   ```
   LABEL=PS4BOOT  /boot  vfat  defaults,noatime  0  0
   ```
   Then `/boot` always has the kernel mounted. Update workflow becomes
   single-line: `scp output/6.x-baikal/bzImage ps4:/boot/bzImage`.

3. **`scripts/scp-initramfs.sh`** — same for initramfs.

4. **Safety**: keep `bzImage-stable` and `rollback-kernel.sh` ready —
   if a build doesn't boot to SSH, we need physical access to recover.

Caveat: these all assume PS4 reaches SSH. Since v76b, we've had clean
SSH every iteration (UVD failure rolls back amdgpu but doesn't crash
the kernel). If we hit a regression that kills SSH, fall back to
physical swap until fixed.
