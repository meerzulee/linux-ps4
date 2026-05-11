# Room: hdmi — HDMI Bridge Control

**Source path embedded:** `sys/internal/modules/hdmi/hdmi.c` @ string `c8eb6798`

**Function address range:** ~`c8a63a00..c8a71800` (heuristic — large single file)

## What this room does

The `hdmi` module is the **userspace ↔ HDMI bridge controller**. It
talks to whatever HDMI transmitter chip is on the Baikal/Liverpool SoC
and exposes:

- An **IOCTL surface** (~30 commands, magic `0x8D`) for userspace
  HDMI control (mode set, audio routing, HDCP, AVI infoframes, etc.)
- A **kernel event processor thread** (`SceHdmiEvent`) that handles
  async events from the bridge: hotplug, EDID changes, HDCP auth
  state, audio sample-rate changes.

This module is **directly relevant** to our Linux DRM port — we have
`ps4_bridge.c` in our patches doing similar work for amdgpu, but it's
incomplete. Sony's hdmi.c shows us the exact bring-up sequence.

## Why it matters for Linux on PS4

🚨 **This is the high-value room.** Our PS4 Linux can't display
because the HDMI bridge isn't fully initialized. Mainline crashniels
fork has a bridge driver but it's missing pieces (we've been seeing
"white screen" and "Cannot find any crtc or sizes" failures).

Sony's hdmi.c is a complete, working HDMI driver for the same bridge
chip. Mapping it gives us:
1. The 7-state event-driven connection state machine
2. The mutex/condvar synchronization Sony uses
3. The IOCTL contract that downstream Sony userspace expects
4. Hints about HDCP authentication flow (case 2 in the event thread)

## Function map (first-pass)

### Top-level

| Sony function | Address | Purpose |
|---|---|---|
| **`hdmi_ioctl`** | `c8a64e70` | **Main IOCTL dispatcher** — see table below |
| **`hdmiProcEvent`** | `c8a645b0` | **Event-processing kernel thread** (SceHdmiEvent) |
| `hdmi_helper_1` | `c8a640b0` | (xref only — string mention) |
| `hdmi_helper_a40` | `c8a64a40` | (xref only — string mention) |

### State / connection management

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `hdmi_power_on` | `c8a686e0` | Power-on sequence (called from cmd 0x01) |
| `hdmi_state_set` | `c8a63bb0` | Set state variable + notify subscribers via mbus |
| `hdmi_is_connected` | `c8a63df0` | Returns char — "is bridge in CONNECTED state" |
| `hdmi_hpd_clear` | `c8a6e3f0` | Clear HPD interrupt (event type 1 handler) |
| `hdmi_hpd_off` | `c8a69d20` | Disable HPD (event type 4 path) |
| `hdmi_hpd_query` | `c8a69d50`, `c8a69d60`, `c8a69d70` | Query HPD state (different variants) |

### Mode / format

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `hdmi_mode_set_apply` | `c8a65690` | Apply mode-set to bridge (event type 3 path) |
| `hdmi_mode_set_blank` | `c8a666e0` | Blank output (event type 4 path) |
| `hdmi_avi_infoframe_set` | `c8a65900`, `c8a65890`, `c8a65990` | AVI infoframe writes (~3 variants by ioctl cmd) |
| `hdmi_video_format_get` | `c8a65730` | Read video format from bridge |
| `hdmi_pixel_clock_set` | `c8a65960` | Pixel clock config |
| `hdmi_force_mode` | `c8a708c0` | Force a mode (cmd 0x19, requires state==3) |
| `hdmi_mode_to_timings` | `c8a70a30` | Convert mode → timing params |
| `hdmi_apply_timing` | `c8a707e0` | Apply timing params to bridge |
| `hdmi_apply_timing_ext` | `c8a707e0` | (variant called with sub-params from cmd 0x12) |

### HDCP / authentication

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `hdmi_hdcp_check` | `c8a6f950` | HDCP status query |
| `hdmi_hdcp_auth_kick` | `c8a6f960` | HDCP auth re-initiate |
| `hdmi_hdcp_verify` | `c8a6bf40` | Returns 0 if HDCP OK; nonzero if failed |
| `hdmi_hdcp_prep` | `c8a6b900` | Pre-HDCP setup |
| `hdmi_hdcp_finalize` | `c8a6e990` | Finalize HDCP after EDID |

### EDID

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `hdmi_edid_read_apply` | `c8a68f60` | Apply EDID-derived state (cmd 0xc0148d02) |
| `hdmi_edid_query` | `c8a69d70` | Query EDID block (cmd 0xc01c8d03) |

### Audio

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `hdmi_audio_off` | `c8a70340` | Mute audio (event type 4) |
| `hdmi_audio_get` | `c8a70a20`, `c8a70a00` | Audio config query |
| `hdmi_audio_sample_rate_check` | `c8a6b720`, `c8a6b730` | Compare current/desired sample rate (event 6) |
| `hdmi_audio_set` | `c8a6b740` | Apply audio config (event 6 / cmd 0x1E) |

### Misc

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `hdmi_event_post` | `c8a6e410` | Post event into ring (called from various contexts) |
| `hdmi_event_consume` | `c8a6b850` | Consume one event (cmd 0x1E setup) |
| `hdmi_unknown_07` | `c8a6b680` | Cmd 7 handler |
| `hdmi_unknown_0E` | `c8a65890` | Cmd 0xE handler |
| `hdmi_unknown_0B` | `c8a6b950` | Cmd 0xB handler |
| `hdmi_unknown_0F` | `c8a65900` | Cmd 0xF handler |
| `hdmi_unknown_1B` | `c8a6ea30` | Cmd 0x1B handler |

## IOCTL surface (`hdmi_ioctl`)

Magic byte: **`0x8D`** (Sony's HDMI ioctl group). Format
`0xCSSS_8DCC` where:
- `0xC` = direction bits (`_IOC_INOUT`)
- `0xSSS` = size of argument in bytes
- `0x8D` = group ID
- `0xCC` = command number

| ioctl value | cmd | arg size | Handler | Purpose (inferred) |
|---|---|---|---|---|
| `0x20008d01` | 1 | 0 | `hdmi_power_on` | Power on HDMI (sets state=1) |
| `0x20008d17` | 0x17 | 0 | `hdmi_f710` | ? (TBD — `f710` |
| `0x20008d1f` | 0x1F | 0 | `hdmi_bdf0` | ? (TBD — `bdf0` |
| `0xc0048d05` | 5 | 4 | `hdmi_a7c0(arg, 0)` | Mode select (arg < 2) |
| `0xc0048d08` | 8 | 4 | `hdmi_5960` | Pixel clock config |
| `0xc0048d0a` | 0xA | 4 | `hdmi_3d30(&arg)` | ? |
| `0xc0048d11` | 0x11 | 4 | `hdmi_b6e0` | ? |
| `0xc0048d13` | 0x13 | 4 | `hdmi_71140` | ? |
| `0xc0048d14` | 0x14 | 4 | `hdmi_70a30` + `hdmi_707e0` | Mode-set apply (TIMING) |
| `0xc0048d16` | 0x16 | 4 | `hdmi_686b0(arg)` | ? |
| `0xc0048d18` | 0x18 | 4 | `hdmi_aba0` | ? |
| `0xc0048d19` | 0x19 | 4 | `hdmi_708c0` | **REQUIRES state==3** — force mode |
| `0xc0048d1c` | 0x1C | 4 | `hdmi_9d40` | HPD query/wait? |
| `0xc0048d1e` | 0x1E | 4 | `hdmi_b850` + `hdmi_b740(arg,0)` | Audio sample rate set |
| `0xc0048d20` | 0x20 | 4 | `hdmi_716c0(arg)` | ? |
| `0xc0048d21` | 0x21 | 4 | `hdmi_be00(arg,0)` | ? |
| `0xc0068d09` | 9 | 6 | `hdmi_95d0(&arg)` | ? |
| `0xc0088d0b` | 0xB | 8 | `hdmi_b950(arg)` | **MUTEX-protected** — `hdmi_data` |
| `0xc0088d0c` | 0xC | 8 | `hdmi_3d90(arg)` | ? |
| `0xc0088d0d` | 0xD | 8 | `hdmi_f970(arg)` | ? |
| `0xc0088d0e` | 0xE | 8 | (NOP) | Empty case |
| `0xc0088d0f` | 0xF | 8 | `hdmi_5900(&arg)` | **MUTEX-protected** |
| `0xc0108d07` | 7 | 16 | `hdmi_b680(arg)` | **MUTEX-protected** |
| `0xc0108d0e` | 0xE | 16 | `hdmi_5890(&arg)` | **MUTEX-protected** |
| `0xc0108d10` | 0x10 | 16 | `hdmi_5990(&arg)` | AVI infoframe? |
| `0xc0108d15` | 0x15 | 16 | `hdmi_5730(&arg)` | Get video format |
| `0xc0108d1a` | 0x1A | 16 | `hdmi_fec0(&arg)` | ? |
| `0xc0108d1b` | 0x1B | 16 | `hdmi_ea30(&arg)` | **MUTEX-protected** |
| `0xc0148d02` | 2 | 20 | `hdmi_8f60(&arg)` | **Connected-only** — EDID-derived state apply |
| `0xc0188d12` | 0x12 | 24 | `hdmi_707e0(arg0,arg1,0)` | Timing apply with sub-params |
| `0xc01c8d03` | 3 | 28 | `hdmi_9d70(&arg)` | **Connected-only** — EDID query |
| `0xc01c8d06` | 6 | 28 | `hdmi_a9a0(&arg)` | ? |

Error codes seen:
- `0x8037000f` — not initialized (returned if `DAT_caaf9c50 != 1`)
- `0x80370001` — invalid arg (when `*param > 1`)
- `0x16` — EINVAL (unknown command, falls through switch)

## Event thread (`hdmiProcEvent` @ c8a645b0)

A kernel thread created via `kthread_create("SceHdmiEvent", priority
0x44, stack 0x200 KB)` that processes events from a 5-slot ring
buffer.

### Event queue layout

```
event_queue:
  &DAT_caaf9170 + slot * 0x228:
    +0x000..+0x020 : ???
    +0x020         : event_payload (up to 0x220 bytes)
    +0x220         : event_payload size (ushort, capped at 0x220)
    +0x224         : event type (int)
```

Read pointer: `DAT_caaf9c38`, write pointer: `DAT_caaf9c3c`.
Wakes via condvar `DAT_caaf9158`, lock `DAT_caaf9118`.

### Event types

| Type | Trigger | Action |
|---|---|---|
| **1** | HPD asserted | `hdmi_hpd_clear` → notify state 1 |
| **2** | EDID + HDCP request | Read EDID via mutex, HDCP verify, → notify state 2 |
| **3** | HPD stable | Set state=3, run mode-set apply, → notify state 4 |
| **4** | Disconnect | HPD off, audio off, blank, display fini |
| **5** | ? generic update | `hdmi_71180` + `hdmi_71190` on event payload buffer |
| **6** | Audio sample-rate change | Check current vs desired sample rate; if mismatch, apply via `hdmi_b740` |
| **7** | Audio reconfig | Resend audio config |
| **0x80** | Thread exit | `kthread_exit()` |
| default | Unknown | printk WARN |

### State variable progression

```
state = 0 (initial / disconnected)
        │
        ↓ ioctl 0x20008d01 (power on)
state = 1 (powered on, awaiting HPD)
        │ ← event type 1: HPD asserted → notify mbus state 1
        ↓ event type 2: EDID + HDCP done
state = 2 (HDCP authenticated, EDID known)
        │
        ↓ event type 3: HPD stable
state = 3 (mode-set capable)        ← ioctl 0x19 enabled only here
        │
        ↓ ?? (after mode-set complete) → notify mbus state 4
state = 4 (display active)
        │
        ↓ event type 4: disconnect
state = 0 (back to initial)
```

## Key data structures

| Symbol | Address | Purpose |
|---|---|---|
| `hdmi_global_lock` | `DAT_caaf90f8` / `DAT_caaf9118` / `DAT_caaf9138` | Three mutexes — main / event / data |
| `hdmi_data_cv` | name "hdmi_data" | condvar for serialized hot-path |
| `hdmi_data_sem` | `DAT_caaf9c58` | Semaphore (0/1) gated by `hdmi_data_cv` |
| `hdmi_init_state` | `DAT_caaf9c50` | 1 once initialized; else ioctl returns `0x8037000f` |
| `hdmi_state` | `DAT_caaf9c54` | 0..4 connection state |
| `hdmi_edid_buf` | `DAT_caaf9c60` | 256-byte EDID buffer |
| `hdmi_edid_extra` | `DAT_caaf9c61` | EDID extension count |
| `hdmi_event_q_rd` | `DAT_caaf9c38` | Event queue read ptr |
| `hdmi_event_q_wr` | `DAT_caaf9c3c` | Event queue write ptr |
| `hdmi_event_q_base` | `DAT_caaf9170` | Event queue base (5 × 0x228 entries) |
| `hdmi_data_passthrough` | `DAT_caaf9c40` | ? (used in event type 7) |

## Open questions / TODOs

1. **Identify the bridge chip register interface.** All the
   `hdmi_xxxxx` functions ultimately read/write some MMIO. Find one
   that does an I2C transaction — that gives us the I2C bus number
   for the bridge.
2. **Trace cmd 0x01 (`hdmi_power_on`) in detail** — what registers
   does Sony write to bring the bridge out of reset? This is what
   our `ps4_bridge.c` is missing for HDMI to work in Linux.
3. **HDCP keys** — `c8a6bf40` (HDCP verify) probably reads from
   SBL/SAMU. That's where keys are stored. We don't have those.
   Means we can't replicate HDCP. Probably fine — Linux doesn't
   need HDCP for basic display.
4. **Mode timing tables** — `c8a70a30` (mode → timings) likely
   contains a hardcoded mode table. Need to extract for our DRM
   bridge driver's `mode_valid()` callback.
5. **EDID read mechanism** — `c8a68f60` (EDID apply) probably calls
   into i2c subsystem. Find the I2C address (typically 0x50 for DDC).

## Linux equivalent

- **IOCTL surface** → Linux has `DRM_IOCTL_MODE_*` for the same set of
  operations. We don't need to replicate Sony's `0x8D` magic — userspace
  on Linux uses DRM directly.
- **Event thread** → Linux DRM uses `drm_kms_helper_hotplug_event` +
  `wait_event_interruptible` patterns. Our `ps4_bridge.c` needs
  equivalent state machine logic.
- **`SceHdmiEvent` kthread** → would map to a `workqueue_struct` in
  Linux, scheduled from the bridge's IRQ handler.

For getting display working on Linux: priority TODOs from this map:
1. **Replicate `hdmi_power_on` register sequence** in `ps4_bridge.c`.
2. **Implement event types 1/3 transitions** (HPD assert → mode set apply).
3. **Skip HDCP** (Sony's event type 2 has HDCP; we can short-circuit and just do EDID).
4. **Extract Sony's mode timing table** for our DRM bridge `mode_valid()`.
