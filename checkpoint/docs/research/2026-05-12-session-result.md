2026-05-12 — Session result: working Linux desktop on PS4 (SW-rendered)
========================================================================

**Branch:** `wip/uvd-vce-poc`
**Duration:** ~14 hours
**Status:** 🎉 **Linux desktop running on PS4 HDMI (software-rendered Weston)**
**Total commits today:** 17

---

## TL;DR

After 18 UVD iterations (A1-A19) + 17-iteration Orbis kernel dungeon mapping
+ 3 Ghidra deep-dives on the SBL subsystem, we have:

- ✅ amdgpu probes successfully (UVD + VCE both soft-fail gracefully)
- ✅ HDMI bridge brings up display via ICC chunks A/B/C
- ✅ DRM connector HDMI-A-1 enabled at 1920x1080@60
- ✅ **Weston desktop running on HDMI** with USB keyboard + mouse
- ✅ Software-rendered (Pixman) — zero GPU faults under load
- ⚠️ Hyprland fails due to GFX VM faults (B1.1 territory — next session)
- 📋 SBL port fully scoped — Phase 1 is ~70 LoC

---

## Today's commits

| Commit | What | Outcome |
|---|---|---|
| `88efe4a` | B1 per-vmid PD (untested) | (earlier) |
| `ca960af` | Ghidra: Orbis pre-UVD-init dig | (earlier) |
| `042f32d` | B1 + A17 results | UVD post-mortem |
| `ee9ae95` | Dungeon iter 1: ENTRANCE + regmgr | start |
| iter 2-16 | 30 rooms mapped (10 floors) | dungeon complete |
| `3332698` | Dungeon cleared 🐉 | 130+ files documented |
| `8e5324e` | A18: UVD soft-fail | ✅ proven |
| `d2219fc` | A19: VCE soft-fail | ✅ proven, Hyprland LIVED briefly |
| `54c4636` | SBL port plan v1 | initial scope |
| `71dfb27` | Ghidra round 2: Finalize + MsgTask + IRQ 0x98 | structural |
| `27f44a3` | Ghidra round 3: Initialize decoded | Phase 1 = ~70 LoC |
| (this) | Session result | wrap-up |

---

## Key technical findings

### 1. UVD/VCE structural failure root-caused

Through 17 hardware iterations + Ghidra dungeon mapping we proved:
- The UVD VCPU firmware waits on chip state set by Sony's SMU at runtime
- SMU registers are locked from CPU writes on retail PS4
- Only the SAMU security co-processor can write SMU (and SAMU runs Sony's
  signed firmware)
- PSFree compromises FreeBSD ring 0 but NOT SAMU
- → Without porting Sony's SBL driver to Linux, UVD/VCE can't work

A18 (uvd_v4_2_hw_init) and A19 (vce_v2_0_hw_init) implement "soft-fail":
return 0 instead of propagating the error, so amdgpu probe completes and
the rest of the GPU (DRM/display/GFX/SDMA) initializes normally.

### 2. HDMI bridge ICC sequence works

Per `rooms/hdmi.md` decoding, Sony's HDMI bring-up sends ICC payloads to
the bridge chip (MN864729 = "Flava2" on PS4 Slim). Our `ps4_bridge.c`
(extensive crashniels work) already implements equivalent chunks A/B/C.
Boot logs confirm all three succeed (rc=20 = success). HDMI-A-1 enabled,
1920x1080@60.

### 3. GFX hangs are VM faults, NOT clock issues

When Hyprland tries to render, the GFX engine's CPF (Command Processor
Fetcher) gets a VM fault at vmid 1, page 616 (VA ~0x268000). Not a clock
issue, not a power-state issue — the GMC's page table doesn't have a
mapping the GPU expects.

This is the **same kind of issue** we hit with UVD's VCPU at VA 0x300000000.
Both stem from Sony's `gbase_create_vmid` per-VMID PD architecture vs
mainline amdgpu's flat-GART model.

PM-disable bootargs (`amdgpu.gfx_off=0 runpm=0 bapm=0 dpm=0`) confirmed
DO NOT help — the issue is structural in the GMC/VMID layout.

### 4. Software-rendered Wayland fully works

`weston --backend=drm --use-pixman` runs a complete Wayland session at
1920x1080. Verified:
- HDMI display ✅
- USB keyboard + mouse ✅
- Wayland apps work ✅
- Zero GPU faults under load (Pixman bypasses GFX ring)
- Stable load avg ~0.9

### 5. SBL port is feasible and fully scoped

Three Ghidra rounds extracted complete picture of Sony's SBL driver:
- `sceSblDriverInitialize` (FUN_c89b7380) — full sequence
- `sceSblDriverFinalize` (FUN_c89b7bf0)
- `sceSblDriverReadSmuIx` (FUN_c89b80b0) — wire protocol decoded
- `sceSblDriverWriteSmuIx` (FUN_c89b81d0) — wire protocol decoded
- SAMU IRQ vector = 0x98
- Mailbox mmio = GPU BAR offsets 0x22070..0x2207c, 0x32, 0x4a

**For Linux Phase 1 port:** ~70 lines of C for `ps4_sbl_read_smu` and
`ps4_sbl_write_smu`. Documented in `sbl-port/PLAN.md`.

---

## What works today (procedure)

1. Build kernel with A18+A19 patches (current `wip/uvd-vce-poc` head)
2. Boot with bootargs containing:
   ```
   amdgpu.gpu_recovery=0 amdgpu.lockup_timeout=10000
   ```
3. After boot, SSH in:
   ```bash
   sudo pacman -S --noconfirm weston
   sudo systemctl enable --now seatd
   sudo usermod -aG seat ps4 root
   ```
4. Start Wayland session:
   ```bash
   export XDG_RUNTIME_DIR=/run/user/0
   sudo mkdir -p $XDG_RUNTIME_DIR
   sudo XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR weston \
       --backend=drm --use-pixman --shell=desktop &
   ```
5. Desktop appears on HDMI. Run Wayland apps via:
   ```bash
   WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/0 firefox-wayland
   ```

---

## What doesn't work + why

| Feature | Status | Root cause |
|---|---|---|
| GL/3D acceleration (Hyprland) | ❌ | VM faults at vmid 1 GFX. B1.1 fix needed. |
| Hardware video decode (UVD) | ❌ soft-failed | SBL/SMU port required |
| Hardware video encode (VCE) | ❌ soft-failed | SBL/SMU port required |
| HDCP-protected video | ❌ | SAMU exclusive |
| GPU suspend/resume | ❌ | depends on SMU/SBL |
| WiFi (mt7668) | ❌ not ported | mt76 mainline driver port needed (days) |
| Bluetooth | ❌ not ported | same chip, same situation |

| Feature | Status |
|---|---|
| HDMI display @ 1080p60 | ✅ |
| HDMI audio | ✅ |
| USB keyboard/mouse | ✅ |
| DualShock 4 (USB) | ✅ via hid-sony |
| Ethernet (Baikal GbE) | ✅ |
| USB drives | ✅ |
| Internal SATA HDD reading | ❌ encrypted, SBL needed |
| Software-rendered Wayland | ✅ |
| Linux kernel 6.15.4 | ✅ |

---

## Three roads forward (in priority order)

### Road A: B1.1 — fix GFX VM faults
**Goal:** GL-accelerated Hyprland / KDE / GNOME
**Effort:** ~hours to days
**Approach:** Finish the per-vmid 2-level PD work we sketched in B1.
This time map BOTH the low VAs (where amdgpu binds IB pool / textures /
vertex buffers) AND any high VAs UVD-style work would need. Per
`rooms/dce.md` we know the IH packet layout matches mainline amdgpu,
so debugging will be straightforward.

### Road B: SBL port Phase 1
**Goal:** Read/write any SMU register from Linux. Foundation for UVD/VCE/HDCP.
**Effort:** ~70 LoC for primitives + ~hours to wire amdgpu calls
**Approach:** Implement `ps4_sbl_read_smu/write_smu` per the snippet in
`sbl-port/PLAN.md`. Add debugfs entry for SSH probing. First test:
read a known SMU register, see if SAMU responds at all (auth question).

### Road C: WiFi/BT port
**Goal:** Wireless without Ethernet
**Effort:** Days, no RE needed
**Approach:** Add PS4 PCI subsystem IDs to mainline mt76 driver,
extract `trooper.bin` firmware from PUP. Per `rooms/wireless.md` this is
straightforward.

---

## Files added/modified today

```
checkpoint/docs/research/orbis-dungeon/          # 17 rooms + INDEX + SUMMARY
checkpoint/docs/research/sbl-port/PLAN.md        # SBL Phase 1 scaffold
patches/6.x-baikal/0300-gpu-liverpool/
    0054-amdgpu-uvd-v4-2-a18-soft-fail-hw-init.patch
    0055-amdgpu-vce-v2-0-a19-soft-fail-hw-init.patch
checkpoint/uart-logs/2026-05-12_*.log            # 4 boot logs
```

---

## Open questions for next session

1. **Does the SAMU respond to Linux mailbox writes?** First test of Phase 1
   answers this. If yes, port is straightforward. If no, deeper RE needed
   on authentication.
2. **What VAs does Hyprland's IB use?** Boot log shows fault at page 616
   (VA 0x268000) but the actual range depends on what BOs Hyprland allocates.
   Trace via amdgpu's BO debug printk.
3. **Is the GFX fault deterministic?** Always page 616, or different each
   time? If always 616, single missing PTE. If random, broader GMC issue.

---

## Commit-ready bzImage

| File | md5 | Active |
|---|---|---|
| output/6.x-baikal/bzImage | `8499c4dff9aaa5a4f3d53d23dbfd92dc` | yes |

USB has it staged at /mnt/usb0/bzImage. Active bootargs:
```
... amdgpu.gpu_recovery=0 amdgpu.lockup_timeout=10000
    amdgpu.gfx_off=0 amdgpu.runpm=0 amdgpu.bapm=0 amdgpu.dpm=0
```

(The last 4 PM-disable params are vestigial from option C testing —
they're not needed. Next session can drop them.)

---

## Final note

This was a substantial day. Going into the session we had: nothing
displaying on HDMI, UVD blocked at iteration 17, no map of Sony's
kernel. Going out: working software-rendered Wayland desktop on PS4,
complete map of Sony's kernel, scoped path to fix everything that
remains.

🎉
