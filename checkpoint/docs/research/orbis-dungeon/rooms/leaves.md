# Room: leaves — Final 6 small modules

This room covers the final 6 small modules that didn't warrant their
own dedicated rooms.

## Source paths

| Module | File | String addr | Floor |
|---|---|---|---|
| `core` | (kernel infrastructure) | n/a | 1 |
| `dbggc` | `dbggc/{exception_event,exception_handler,dbggc}.c` | `c8bb49d3`, `c8bb610d`, `c8bb6d95` | 2 |
| `screenshot` | `screenshot/screenshot.c` | `c8eaf78d` | 2 |
| `ajm` | `ajm/Service/*.cc` (~14 files) | `c8cb4da4` etc. | 4 |
| `s3da` | `s3da/s3da.c` | `c8ed1459` | 4 |
| `sdbgp` | `sdbgp/sdbgp_main.c` | `c8eba607` | 10 |

## 🛠️ `core` — Kernel infrastructure

This is implicit in the codebase — no `internal/modules/core/`
directory exists. "Core" refers to:
- BSD kernel infrastructure (proc, vfs, vm) inherited from FreeBSD 9
- Boot-time SYSINIT / mi_startup chain (covered in [ENTRANCE.md](../ENTRANCE.md))
- Per-CPU GS_OFFSET layout
- GDT/IDT/TSS setup
- EFER MSRs + SYSCALL infrastructure

These are **standard FreeBSD 9 code** — Sony forked the kernel but
made minimal changes to the core abstractions. For a full mapping,
read FreeBSD 9.0 kernel source code directly; Sony's mods are
isolated to the `internal/modules/*` directories we've been
mapping.

**Linux equivalent:** Linux's own kernel infrastructure.

## 🐛 `dbggc` — Debug GC (GPU exception trapping)

Three source files:
- `exception_event.c`
- `exception_handler.c`
- `dbggc.c`

Catches GPU-level exceptions (page faults, bad CP packets, RLC traps)
and reports them to a userspace debugger via shared memory. "dbggcknl"
is the kernel-mode service name.

Key functions identified from strings:
- `dbggc_push_only_protection_fault_info_to_user` — VM-fault info push
- `dbggc_push_only_bad_packet_to_user` — invalid CP packet push
- `dbggc_report_to_user` — generic report path

Error strings:
- `"#### dbggc invalid reg access. addr:0x%08x"` — caught a forbidden GPU register access
- `"#### dbggc invalid reg access with gfx_index. addr:0x%08x"` — same with GFX_INDEX context

This is what gives Sony's SDK the `sceGpuDebug*` family — used by
game devs to debug GPU hangs / crashes during development.

**Linux equivalent:** amdgpu's `debugfs/dri/0/amdgpu_*` files plus
`amdgpu_gpu_recover` notifications. Mainline has equivalent debug
infrastructure already.

## 📸 `screenshot` — System screenshot capture

Implements the PS4 "Share" button screenshot capture path.
Per the prior `dce` room, it likely uses the `dce/scanin_capture/`
hardware to grab a framebuffer copy without disturbing scanout.

Key strings:
- `SceScreenShot` — kernel service name
- `SceScreenShotUtil` — utility helper service

**Linux equivalent:** `grim` / `wlroots screencopy` (Wayland), or
`scrot` / xdotool (X11), or just `cat /dev/dri/card0/...` with
DRM dumb buffer mapping. Mainline has all of these via DRM.

## 🎵 `ajm` — Audio Jagged Multi-decoder Service

A C++-implemented audio service module — by far the most C++ code
in the kernel (most of Sony's stuff is C). Provides multi-format
audio decoding for game audio:
- AAC, MP3, AT9 (Sony's ATRAC9), Vorbis, Opus, etc.

~14 .cc files structured around a "BatchWait/BatchMisc" pattern for
async decode jobs:
- `Service/BatchWait.cc`
- `Service/BatchMisc.cc`
- `Service/Codec.cc`
- `Service/Suspend.cc`
- `Service/Context.cc`
- `Service/Memory.cc`
- `Service/Module.cc`
- `Service/Interface.cc`
- `Service/ACP.cc`
- `Service/mios2/MemoryFragment/MemoryFragment.cc`
- `Service/mios2/Platform_orbisos.h` (header included multiple times)

Note: `mios2` = multi-instance OS layer 2 — Sony's portable abstraction
for running on either Orbis OS (PS4) or other targets. The `Codec.cc`
file likely has the codec dispatch table.

**Linux equivalent:** GStreamer / FFmpeg / Pulse with audio codec
plugins — equivalent functionality but very different architecture.
Game ports on Linux generally bundle ffmpeg or implement their own
decoders; no need to port `ajm`.

## 🔊 `s3da` — 3D Audio Engine

Spatial 3D audio decoder. Used for:
- PSVR ear-mounted headphones with HRTF processing
- 3D-audio-capable headsets (Sony Pulse, etc.)
- Atmos/DTS:X-style positional audio

Key strings:
- `SceS3da%1d` — per-instance service name (S3da0, S3da1, ...)
- `s3da_usleep` — timing helper (usleep wrapper)
- `s3daTempBuff` — work buffer name
- `_s3daInit()` — init function
- `"S3DA 3DAUDIO MAXUNIT reached : unit %d"` — fixed instance limit
- `"_s3daInit() : TempBuffer[%d] malloc error"` — alloc failure

The "%1d" format implies max 10 instances (single-digit). Multiple
instances would be one per game/app that wants 3D audio (probably one
per running PSVR title).

**Linux equivalent:** OpenAL Soft (with HRTF), Steam Audio,
PipeWire's spatial-audio module. Mainline has good 3D audio support;
no port needed.

## 🐞 `sdbgp` — System Debug Print

System-wide kernel debug print. Equivalent to `printk` with
filtering / level control.

**Linux equivalent:** `printk` + `dmesg`. Already covered.

## Summary

These 6 leaves complete the dungeon. None require Linux porting:

| Module | Linux porting needed? |
|---|---|
| core | No (we have Linux's own core) |
| dbggc | No (mainline amdgpu has equivalent debug) |
| screenshot | No (DRM dumb buffer + grim/scrot) |
| ajm | No (FFmpeg + GStreamer) |
| s3da | No (PipeWire + OpenAL Soft + HRTF) |
| sdbgp | No (printk) |

## Connections to other rooms

- **dbggc** → **gc**: catches GPU exceptions originated from gc.
- **dbggc** → **uvd / vce**: also catches their faults.
- **screenshot** → **dce/scanin_capture**: uses DCE capture path.
- **ajm** → **audioout**: feeds decoded audio into audioout's pcm
  channel.
- **s3da** → **audioout** + **hmd**: PSVR-mounted spatial sound.
- **sdbgp** → all rooms (debug print is universal).
