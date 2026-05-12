# 2026-05-12 — B1.1-α (DEPTH=0 revert) — hardware result

**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0056-amdgpu-gmc-v7-0-b11-alpha-revert-depth-override.patch`
**Boot log:** `checkpoint/uart-logs/2026-05-12_1521-b11-alpha-depth1-revert.log`
**bzImage md5:** `218f42bf6b7bac93a5ddf7201b86b27d` (size 11,432,960)
**Status:** ✅ **WIN — GFX VMID 1 page-616 fault eliminated, Hyprland GL-renders.**

---

## Change in one sentence

Removed β-2-A's `WREG32(VC1_CNTL, DEPTH=0)` override so VC1..VC15 use mainline `DEPTH=1` again. amdgpu_vm's per-vmid PT_BASE writes are no longer silently swallowed by the GMC.

---

## Signal counts (vs v76e-A19 baseline)

| Signal                                        | v76e-A19 | B1.1-α   | Reading |
|-----------------------------------------------|----------|----------|---------|
| `VC1..VC15 PAGE_TABLE_DEPTH overridden`       | 1 boot   | **0**    | 0056 applied. |
| `VM fault … vmid 1 … page 616 … CPF`          | ≥1 / Hyprland frame | **0** | The breakage is gone. |
| `VM fault … vmid 15 … page 3,145,728 … UMC`   | 0        | 50 + ~10 callback-suppressed bursts during t=10–30s | UVD/VCE bring-up sees its hardcoded VA 0x300000000 with no per-vm PD entry. Transient, stops once A18+A19 soft-fail kick in. |
| `[drm] PCIE GART of 16384M enabled`           | yes      | yes      | gart_enable still runs. |
| `[drm] Initialized amdgpu 3.63.0`             | yes      | yes (t=31.96 s) | probe completes. |
| HDMI-A-1 `connected` + `enabled`              | yes      | yes      | display works. |
| `ring gfx timeout` / `Ring gfx reset failure` | yes (under Hyprland) | **0** | GFX no longer hangs on user IBs. |
| Hyprland GL frames composed                   | 0        | **≥14**  | First time Hyprland has rendered on PS4 Linux. |

---

## Boot timing milestones

| t (s) | Event |
|-------|---|
| 7.59  | amdgpu detects `gmc_v7_0` |
| 7.81  | `bound dummy page at GART virtual 0x300000000` (the harmless flat-GART bind, now inert under DEPTH=1) |
| 7.83  | `[drm] PCIE GART of 16384M enabled (table at 0x0000000F02000000)` |
| 10.09 | **First vmid-15 UMC fault** at page 3,145,728 — UVD probe's read of VA 0x300000000 has no per-vm mapping. Storm begins. |
| 20.26 | `ps4 uvd: hw_init failed (-110) — soft-failing per v76e-A18` — A18 catches and stops UVD bring-up. |
| 30.86 | `ps4 vce: ring[0] test failed (-110) — soft-failing per v76e-A19` — VCE same path. Storm ends. |
| 31.96 | `[drm] Initialized amdgpu 3.63.0 for 0000:00:01.0` — probe completes. |
| 32.28 | `fbcon: amdgpudrmfb (fb0) is primary device` |

UVD/VCE soft-fail latency (~20 s of dummy faults) is a cosmetic boot-time cost; the GMC's fault handler returns dummy_page_addr data each time so the VCPU loops on garbage until A18/A19 fire. Not user-visible after the desktop is up — `dmesg | grep "VM fault" | wc -l` stays at 50 through 27 minutes of uptime.

---

## What killed Hyprland (and why it's not our problem)

After Hyprland successfully:
- enumerated the GPU (`AMD/ATI Starsha2 [Kingston/Clayton] [1002:9923]`)
- allocated GBM buffers (modifier-less; expected on Liverpool/Pixman)
- configured Wayland toplevels (`configure toplevel with 990x550` × multiple)
- spawned a user app that produced an xkb keymap and dconf writes

…aquamarine asserted on `[core] Disconnected from pollfd id 0` at `Backend.cpp:367`.

Root cause is *not* amdgpu. Concurrent dmesg shows:

- `drkonqi` (KDE's crash handler) segfaulting in `libQt6Core.so.6.11.0` at IP `205b63` (NULL-pointer deref) **every 25–35 s since t=1373 s** — 13 spawns observed in a single dmesg snapshot.
- Each invocation crashes the same way → KDE re-launches → loop.
- Hyprland's autostart + Plasma/Qt6 cascade fed aquamarine a flood of dying clients, eventually breaking pollfd-0.
- `(process:2634): dconf-WARNING **: Cannot autolaunch D-Bus without X11 $DISPLAY` confirms the misconfig.

Conclusion: GL Wayland on Liverpool **works** under α. The crash chain is a userspace yak (KDE/Qt 6.11 + dconf/D-Bus + Hyprland aquamarine edge case), parked.

---

## The EnableCRTC bursts — investigated, benign

Initial concern was a continuous loop of `EnableCRTC → ASIC_StaticPwrMgtStatusChange → DynamicClockGating` ATOM-table calls. Empirical observation:

- `dmesg | grep -c EnableCRTC` stayed at exactly **365** across a 2-s sample → **zero new calls at idle**.
- All 365 occurrences cluster in bursts at mode-change events: boot mode-set (t≈39 s), fbcon up (t≈62–64 s), Hyprland startup (t≈1528 s), Hyprland teardown (t≈1556 s).
- ~50 ATOM-table calls per mode change × 10 ms each ≈ 500 ms per burst. Wasteful per individual mode change but bounded in time and not actively running.

Not a runaway loop. The `tail`-of-`ps4_atom` output happens to land in the most recent burst, which made it look continuous on first look. Nothing to fix in α; might revisit if a future workflow churns mode-set frequently.

---

## Hypotheses for next steps

The structural blockers identified during the A-arc + dungeon mapping (UVD/VCE need SBL/SMU access; HDCP needs SAMU; GPU recovery needs ATOM via ICC) are unchanged. α only resolved one specific symptom (GFX VMID 1 page-616). The plan from `sbl-port/PLAN.md` stands:

1. **SBL Phase 1** (next iteration): `ps4_sbl_read_smu` / `ps4_sbl_write_smu` primitives — ~70 LoC for synchronous mailbox primitives, with a debugfs entry to probe from userspace. First probe answers the open question: does SAMU respond to Linux mailbox writes at all?
2. **(parked, low priority)** Trim the vmid-15 UVD-VA-0x300000000 fault burst. A18+A19 already catch it; only cosmetic. Could either earlier-abort the UVD/VCE start path (so the VCPU never tries the access) or bind dummy/mirror in VMID 15's per-vm PD. Not blocking anything.
3. **(parked, userspace)** Fix the Plasma + Qt6 crash cascade so KDE-stack compositors can be used as a backup test surface. Not on the kernel critical path.

---

## Files touched

```
patches/6.x-baikal/series                                            # add 0056
patches/6.x-baikal/0300-gpu-liverpool/0056-amdgpu-gmc-v7-0-b11-alpha-revert-depth-override.patch
checkpoint/docs/research/2026-05-12-b11-alpha-result.md              # this doc
checkpoint/uart-logs/2026-05-12_1521-b11-alpha-depth1-revert.log     # raw boot evidence
```
