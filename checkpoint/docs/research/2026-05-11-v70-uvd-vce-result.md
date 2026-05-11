# v70 result — UVD/VCE IP block adds enabled, sw_init second gate exposed

**Date:** 2026-05-11
**bzImage md5:** `9eced3e52589854463f1e52087f03bf1`
**UART log:** `checkpoint/uart-logs/2026-05-11_1138-v70-uvd-vce-enable.log` (2427 lines, 183 KB)
**Hardware result:** ❌ HDMI blank, ✅ SSH up over WiFi
**Verdict:** Patch did what we wanted at the IP-block registration layer; revealed a second gate in `amdgpu_uvd_sw_init` / `amdgpu_vce_sw_init` firmware-name switch.

## What changed in v70

Edited `patches/6.x-baikal/0300-gpu-liverpool/0001-amdgpu-add-ps4-liverpool-bridge.patch`
to strip the `/* ... */` wrappers around the `uvd_v4_2_ip_block` and
`vce_v2_0_ip_block` adds in both `CHIP_LIVERPOOL` and `CHIP_GLADIUS`
branches of `cik_set_ip_blocks()`.

Before (lines 788–789 / 806–807 in the patch):
```c
/*amdgpu_device_ip_block_add(adev, &uvd_v4_2_ip_block)*/;
/*amdgpu_device_ip_block_add(adev, &vce_v2_0_ip_block)*/;
```

After:
```c
amdgpu_device_ip_block_add(adev, &uvd_v4_2_ip_block);
amdgpu_device_ip_block_add(adev, &vce_v2_0_ip_block);
```

## Signal counts (vs v68)

| Signal | v68 | v70 |
|---|---|---|
| `Linux version` | 1 | 1 |
| `bpcie_create_irq_domain` | 16 | 16 |
| `bpcie_msi_write_msg` | ~105 | 105 |
| `detected ip block number 6 <uvd_v4_2>` | 0 | **1** |
| `detected ip block number 7 <vce_v2_0>` | 0 | **1** |
| `ps4_bridge_pre_enable: END` | 1 | 1 |
| `ps4_bridge_enable: END` | 1 | 1 |
| `*ERROR* sw_init of IP block <uvd_v4_2> failed -22` | 0 | **1** |
| `amdgpu: Fatal error during GPU init` | 0 | **1** |
| `WARNING: ... amdgpu_irq_put+0x51/0x60` | 0 | **12** |
| `probe with driver amdgpu failed with error -22` | 0 | **1** |

## Boot timing milestones

| Event | t= |
|---|---|
| `Linux version` | 0.469 s |
| `amdgpu kernel modesetting enabled` | 1.395 s |
| `detected ip block 6 <uvd_v4_2>` | 7.547 s |
| `detected ip block 7 <vce_v2_0>` | 7.554 s |
| `Fetched VBIOS from ROM BAR` | 7.636 s |
| `ATOM BIOS: 113-Starsha2-018` | 7.642 s |
| `forcing HDMI-A-1 connector on` | 7.786 s |
| `ps4_bridge_enable: END` (chunk C done) | 9.709 s |
| **`*ERROR* sw_init of IP block <uvd_v4_2> failed -22`** | **9.740 s** |
| `Fatal error during GPU init` | 9.755 s |
| `probe with driver amdgpu failed with error -22` | 12.863 s |

So the bridge programming finished normally — chunks A (DP lane status),
B (HDMI/update), C (PLL/7204) all returned `rc=20` with elapsed times
within v60's working envelope. The failure happens 30 ms *after* the
bridge is done, in the IP block init phase.

## Root cause

`drivers/gpu/drm/amd/amdgpu/amdgpu_uvd.c::amdgpu_uvd_sw_init` (line 194)
has a `switch (adev->asic_type)` that picks the firmware filename. The
CIK-class arm of the switch covers Bonaire, Kabini, Kaveri, Hawaii,
Mullins — but has no case for `CHIP_LIVERPOOL` or `CHIP_GLADIUS`.
Execution falls through to `default: return -EINVAL` at line 260.

Same issue in `drivers/gpu/drm/amd/amdgpu/amdgpu_vce.c::amdgpu_vce_sw_init`
at line 157.

The `liverpool_uvd.bin` and `liverpool_vce.bin` firmware blobs we ship
in initramfs are never even requested — the switch returns `-EINVAL`
before `amdgpu_ucode_request()` is called. amdgpu_device_ip_init
propagates `-22` upward, the whole probe unwinds with 12 `amdgpu_irq_put`
warnings (one per IP block being torn down without a successful init),
and no fbcon is registered → blank HDMI.

## Why HDMI specifically goes dark despite a successful bridge program

The MN864729 bridge programming sequence (chunks A/B/C) ran to
completion and the connector is still in a programmed state — but
without amdgpu probe succeeding, no DRM framebuffer is created, no
`drm_fb_helper`/fbcon binding happens, and the kernel never writes
anything into the scanout. The display is "primed but unfed."

## v71 candidate fix

`patches/6.x-baikal/0300-gpu-liverpool/0033-amdgpu-uvd-vce-liverpool-firmware-name.patch`
(75 lines):

1. Adds `#define FIRMWARE_LIVERPOOL "amdgpu/liverpool_{uvd,vce}.bin"`
   under `CONFIG_DRM_AMDGPU_CIK` in both files.
2. Adds `MODULE_FIRMWARE(FIRMWARE_LIVERPOOL)` declaration.
3. Adds two switch cases:
   ```c
   case CHIP_LIVERPOOL:
   case CHIP_GLADIUS:
       fw_name = FIRMWARE_LIVERPOOL;
       break;
   ```

Both Liverpool and Gladius share `liverpool_*.bin` because Gladius is
the PS4 Slim refresh of the same GCN 1.1-class APU silicon family;
firmware versions are functionally identical. If a Gladius user
reports a UVD/VCE issue specific to the slim hardware revision, this
can be split into separate `FIRMWARE_GLADIUS` later.

## Expected v71 outcome

Three failure modes to watch for in the next boot:

1. **Best case — UVD/VCE init succeeds:** see `Found UVD firmware Version: X.Y.Z`
   and `Found VCE firmware Version: X.Y.Z` in dmesg, followed by ring
   tests passing. HDMI works again because amdgpu probe succeeds.
   `/dev/dri/renderD128` should appear, and `vainfo` should report
   H.264 decode + encode profiles.

2. **Likely intermediate — firmware load fails:** if
   `liverpool_uvd.bin` has a different header layout than mainline
   Bonaire-class firmware expects, we'd see
   `amdgpu_uvd: Can't validate firmware "amdgpu/liverpool_uvd.bin"` —
   meaning the file was found but `common_firmware_header` parsing
   rejected it. Fix would be a parallel patch to relax the validator,
   or use a Bonaire-compatible blob.

3. **Worst case — UVD ring test fails:** firmware loads but ring init
   times out, suggesting register layout / clock-gating differences
   between Liverpool's UVD block and stock Bonaire UVD 4.2. Would need
   per-chip register overrides.

Whatever the outcome, HDMI should NOT go dark in case 2 or 3 — amdgpu
has explicit fallback logic that disables UVD/VCE on probe failure but
keeps the display path alive (`adev->uvd.num_uvd_inst = 0`, similar
for VCE). The blank-HDMI failure mode in v70 was specific to the
firmware-name switch returning EINVAL at the `sw_init` stage *before*
those fallbacks engage.

## Rollback path if v71 also breaks display

`bzImage-prev` on USB is currently v68 (the post-v67 boot with all
known-good features). If v71 doesn't boot or display stays dark and
SSH is also unavailable, run `rollback-kernel.sh` from host with USB
plugged in to restore `bzImage` from `bzImage-stable` (which is the
v60 HDMI-working baseline).

## Next iteration after v71

If v71 succeeds: ship a small follow-up that disables UVD/VCE behind
a Kconfig (`CONFIG_DRM_AMDGPU_LIVERPOOL_HW_VIDEO`) so users can
opt-out cleanly until the codepath is broadly tested.

If v71 hits case 2 or 3: branch into a new research session for
Liverpool UVD register layout — likely requires reading PS4 firmware
RE notes from feeRnt's tree and/or comparing against the PS4 BSD UVD
driver source if accessible.
