# Floor 8 trio: camera + hmd + hmddfu (+ mas)

## Source paths

**camera (2 files):**
- `sys/internal/modules/camera/camera_utility.c` @ string `c8e9b303`
- `sys/internal/modules/camera/luke.c` @ string `c8eae42b` (**🎬 PS Camera codename**)

**hmd (1 file):**
- `sys/internal/modules/hmd/hmd.c` @ string `c8ec3da9` (PSVR Head-Mounted Display)

**hmddfu (1 file):**
- `sys/internal/modules/hmddfu/hmddfu.c` @ string `c8ec4677` (PSVR firmware update)

**mas (1 file) — adjacent address range, likely related:**
- `sys/internal/modules/mas/mas.c` @ string `c8ec4086`

**Function ranges:**
- `camera/`: ~`c8a126f0..c8a194xx` (very large — likely the biggest single-file code in this trio)
- `hmd/`: ~`c8ab1100..c8ab6100`
- `mas/`: ~`c8ab6640..c8ab85ef`
- `hmddfu/`: ~`c8ab8aa0..c8ab9fa2`

These are all **adjacent in the binary**, suggesting they were
linked together as a "VR/Camera" superblock at build time.

## What this room does

Sony's PlayStation Camera + PlayStation VR (PSVR) device stack. Three
hardware paths:

1. **PS Camera** (USB device, Sony codename "luke") — the stereo IR
   camera used for gameplay tracking.
2. **PSVR HMD** — the actual headset (with built-in lenses + screens
   + IR LEDs + motion sensors).
3. **PSVR processor unit** — the breakout box that does HDMI
   pass-through, lens warp, and head-tracking compute.

Plus auxiliary `mas` (purpose unclear from naming — possibly "Master
device" or "Memory Allocator System" for VR-large buffers).

`hmddfu` = HMD Device Firmware Update — pushes firmware updates to
the headset.

## Why it matters for Linux on PS4

🟡 **Niche** — PSVR is a low-priority feature. Two scenarios:
1. **Without PSVR**: zero impact. PS Camera and HMD are USB devices,
   if not plugged in, the modules don't load.
2. **With PSVR**: would require porting Sony's specific HMD protocol
   (sensor fusion, IR LED tracking, lens warp). Mainline Linux has
   `psvr` driver support since kernel 4.16+ via `hid-sony`'s VR mode
   detection plus userspace OpenHMD/Monado.

For our Linux port, **no work needed**. PS Camera works as a generic
UVC webcam via mainline `uvcvideo`. PSVR works via existing community
Linux drivers (OpenHMD).

## Function map (very brief)

### camera/luke.c (huge — ~200+ functions)

The big handler `FUN_c8a173b0` has 30+ string xrefs and is likely the
main camera IOCTL dispatcher / video-mode selector. The function
`FUN_c8a126f0` (15+ xrefs) is likely USB-side init / probe.

| Sony function | Address | Probable role |
|---|---|---|
| `luke_helper_126f0` | `c8a126f0` | USB probe/attach |
| `luke_video_mode` | `c8a15740` | Set video mode |
| `luke_helper_15840` | `c8a15840` | Mode helper variant |
| `luke_helper_15a40` | `c8a15a40` | Frame helper |
| `luke_helper_15be0` | `c8a15be0` | |
| `luke_helper_15cb0` | `c8a15cb0` | |
| `luke_helper_15d40` | `c8a15d40` | |
| `luke_helper_160c0` | `c8a160c0` | |
| `luke_helper_161f0` | `c8a161f0` | |
| `luke_helper_16320` | `c8a16320` | (~10 xrefs) |
| `luke_helper_16b20` | `c8a16b20` | |
| `luke_helper_16c70` | `c8a16c70` | |
| `luke_helper_16e40` | `c8a16e40` | (PARAM-heavy — major handler) |
| **`luke_main_dispatch`** | `c8a173b0` | **MAIN** — 30+ xrefs |

### hmd/hmd.c

| Sony function | Address | Purpose |
|---|---|---|
| `hmd_helper_1100` | `c8ab1100` | Init |
| `hmd_helper_12b0` | `c8ab12b0` | |
| `hmd_helper_1470` | `c8ab1470` | |
| `hmd_helper_1740` | `c8ab1740` | |
| `hmd_helper_1870` | `c8ab1870` | |
| `hmd_helper_19c0` | `c8ab19c0` | |
| `hmd_helper_1a90` | `c8ab1a90` | |
| `hmd_helper_2070` | `c8ab2070` | |
| `hmd_helper_20e0` | `c8ab20e0` | |
| `hmd_helper_2230` | `c8ab2230` | |
| `hmd_helper_22c0` | `c8ab22c0` | |
| `hmd_helper_2350` | `c8ab2350` | |
| `hmd_helper_2640` | `c8ab2640` | |
| `hmd_helper_2760` | `c8ab2760` | |
| `hmd_helper_2830` | `c8ab2830` | |
| `hmd_helper_28a0` | `c8ab28a0` | |
| `hmd_helper_2980` | `c8ab2980` | |
| `hmd_helper_2ed0` | `c8ab2ed0` | |
| `hmd_helper_2f50` | `c8ab2f50` | |
| `hmd_helper_3090` | `c8ab3090` | |
| `hmd_helper_3940` | `c8ab3940` | (PARAM-heavy) |
| `hmd_helper_3c40` | `c8ab3c40` | |
| `hmd_helper_4210` | `c8ab4210` | (4 xrefs) |
| `hmd_helper_5030` | `c8ab5030` | |
| `hmd_helper_5250` | `c8ab5250` | |
| `hmd_helper_56e0` | `c8ab56e0` | (PARAM-heavy ioctl?) |
| `hmd_helper_5940` | `c8ab5940` | |
| `hmd_helper_6030` | `c8ab6030` | |
| `hmd_helper_6100` | `c8ab6100` | |

### mas/mas.c

| Sony function | Address | Purpose |
|---|---|---|
| `mas_helper_6640` | `c8ab6640` | (PARAM-heavy init) |
| `mas_helper_67c0` | `c8ab67c0` | |
| `mas_helper_75a0` | `c8ab75a0` | (4 xrefs) |
| `mas_helper_7790` | `c8ab7790` | (PARAM-heavy) |
| `mas_helper_7a80` | `c8ab7a80` | (~25 xrefs — major) |
| `mas_helper_80c0` | `c8ab80c0` | (~6 xrefs) |
| `mas_helper_88e0` | `c8ab88e0` | |
| `mas_helper_8aa0` | `c8ab8aa0` | (~5 xrefs) |

### hmddfu/hmddfu.c

| Sony function | Address | Purpose |
|---|---|---|
| `hmddfu_helper_8d90` | `c8ab8d90` | |
| `hmddfu_helper_9000` | `c8ab9000` | |
| `hmddfu_helper_9170` | `c8ab9170` | |
| `hmddfu_helper_9300` | `c8ab9300` | |
| `hmddfu_helper_9370` | `c8ab9370` | |
| `hmddfu_helper_94e0` | `c8ab94e0` | (~4 xrefs — DFU driver dispatcher?) |
| `hmddfu_helper_9e50` | `c8ab9e50` | (PARAM-heavy) |
| `hmddfu_helper_a0e0` | `c8aba0e0` | |
| `hmddfu_helper_a2c0` | `c8aba2c0` | |
| `hmddfu_helper_a430` | `c8aba430` | |
| `hmddfu_helper_a630` | `c8aba630` | |

## Sony codenames decoded

| Codename | Hardware |
|---|---|
| **luke** | PS Camera (CUH-ZEY1 / CUH-ZEY2) |
| **trooper** | MT76xx WiFi/BT (chip) |
| **torus** | USB BT/WLAN combo |
| **ujedi** | DualShock 4 controller |
| **baikal** | Liverpool SoC (PS4 Slim) |
| **gladius** | Liverpool variant (PS4 Pro?) |

(Pattern: Star Wars / Sword & Sorcery — Sony loves codenames.)

## Open questions / TODOs

1. **What is `mas`?** Probably "MAS" = some specific abbreviation.
   Adjacency to hmd in the binary suggests it's HMD-related —
   maybe "Master Audio System" (HMD has built-in audio) or "Motion
   Activity Sensor" (gyro/accel).
2. **Decode luke's video format table** — should be in
   `c8a126f0..c8a13xxx`. Tells us which YUV/MJPEG modes Sony uses.
3. **Map hmd's HID report layout** — how Sony parses the head-tracking
   IMU stream from PSVR.
4. **hmddfu firmware blob path** — `/system/firmware/psvr.bin` or
   similar.

## Linux equivalent

| Sony | Linux mainline |
|---|---|
| `luke.c` (PS Camera) | `drivers/media/usb/uvc/uvc_*.c` (UVC class) |
| `hmd.c` (PSVR) | `drivers/hid/hid-sony.c` (PSVR mode) + OpenHMD/Monado |
| `hmddfu.c` (HMD firmware update) | `drivers/usb/dfu/*` if needed; community tool otherwise |
| `mas.c` (?) | None — depends on what it is |

For Linux on PS4: **no port work needed**. PS Camera works as a UVC
webcam, PSVR works via existing community drivers if anyone wants
VR on Linux on PS4 (very few people).

## Connections to other rooms

- **bt** room: PSVR uses Bluetooth for Move controllers tracking sync.
- **hid** + **hid_application_authentication**: PSVR is HID with
  vendor extensions; auth thread might gate the HMD too.
- **audioout**: PSVR has its own audio sink (in-ear headphones) that
  routes through the audioout stack.
- **dce / hdmi**: PSVR pass-through HDMI connects through these.
