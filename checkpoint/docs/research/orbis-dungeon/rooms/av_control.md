# Room: av_control — Audio/Video Mode + HDR Negotiation

**Source paths embedded:**
- `sys/internal/modules/av_control/main.c` @ string `c8ebd2e0`
- `sys/internal/modules/av_control/crtc.c` @ string `c8ebeb0b`

**Function address ranges (heuristic):**
- `main.c`: ~`c8a80a20..c8a82ab0`
- `crtc.c`: ~`c8a85e50..c8a87b60`

## What this room does

`av_control` is the **kernel-side AV mode/HDR/colorspace controller**.
It sits between userspace AV negotiation (from PS4 OS settings + the
gameOS handshake) and the `dce` + `hdmi` modules. Three roles:

1. **Mode-set IOCTL surface** (magic `0x9A`) — output resolution,
   pixel format, colorspace, HDR mode.
2. **HDR state machine** — tracks colorspace transitions (SDR ↔ HDR10,
   BT.2020 RGB ↔ YCC, etc.) and detects when link training is needed.
3. **CRTC delegation** — passes per-CRTC commands to `crtc.c` (the
   per-display-pipe state).

## Why it matters for Linux on PS4

**Indirectly relevant** but interesting. The HDR colorspace table
decoded from log strings tells us Sony's exact pixel format / colorspace
ID mapping. If we ever want HDR output on Linux (TVs + games that
encode HDR), this is the table we'd match against.

For now (just getting basic display working), this is informational.

## Function map (first-pass)

### main.c — IOCTL dispatcher + HDR state

| Sony function | Address | Purpose |
|---|---|---|
| `av_control_helper_a20` | `c8a80a20` | |
| `av_control_helper_a80` | `c8a80a80` | |
| `av_control_helper_ae0` | `c8a80ae0` | |
| `av_control_helper_b40` | `c8a80b40` | |
| `av_control_helper_ba0` | `c8a80ba0` | |
| `av_control_helper_c00` | `c8a80c00` | |
| `av_control_helper_c70` | `c8a80c70` | |
| `av_control_helper_ce0` | `c8a80ce0` | |
| `av_control_helper_d60` | `c8a80d60` | |
| `av_control_helper_fc0` | `c8a80fc0` | |
| **`av_control_ioctl`** | `c8a810d0` | **Main IOCTL dispatcher** (magic `0x9A`) |
| `av_set_output_mode` | `c8a82180` | Handle cmd `0xc0049a0c` (set output mode by ID) |
| `av_state_query` | `c8a82990` | Handle cmd `0xc0089a1e`, `0xc0049a27` |
| `av_verify_timing` | `c8a82ab0` | Handle cmd `0xc0089a21` (verify timing) |

### crtc.c — per-CRTC commands

| Sony function | Address | Purpose |
|---|---|---|
| **`av_crtc_handler`** | `c8a85e50` | Dispatcher for CRTC IOCTLs (0xc0089a01..06, 08, 09, 28, 29, 0xc0189a07) |
| `av_crtc_helper_5470` | `c8a85470` | (0x20009a12 handler) |
| `av_crtc_helper_5970` | `c8a85970` | Update timing params (called from `update_info` validation) |
| `av_crtc_helper_7140` | `c8a87140` | Handle cmd `0xc0089a13..15`, `0xc00C9a16/17`, `0xc0109a0d..0a`, `0xc0049a1b` |
| `av_crtc_helper_7b60` | `c8a87b60` | Handle cmd `0xc0089a1f`, `0x20009a20` |

## IOCTL surface — magic `0x9A`

Format: `0xC_SSS_9A_CC` (`_IOC_INOUT | size | 0x9A | cmd`).

### No-arg IOCTLs (`0x20009A_CC`)

| ioctl | Action |
|---|---|
| `0x20009a25` | Save current state to `prev_state` (`DAT_caafc4cc = DAT_caafc4c8`) |
| `0x20009a26` | Set "need_link_train" flag (`DAT_caafc4f0 = 1`) |
| `0x20009a0a` | Delegate to `av_crtc_handler` |
| `0x20009a12` | `av_crtc_helper_5470` |
| `0x20009a20` | Delegate to `av_crtc_helper_7b60` |

### 4-byte arg IOCTLs (`0xc0049A_CC`)

| ioctl | Handler | Purpose |
|---|---|---|
| `0xc0049a0c` | `av_set_output_mode` | Set output mode by ID |
| `0xc0049a1b` | `av_crtc_helper_7140` | (CRTC sub-op) |
| `0xc0049a24` | inline | Toggle a power state flag, save prev |
| `0xc0049a27` | `av_state_query` | Query AV state |

### 8-byte CRTC IOCTLs → delegated to `av_crtc_handler`

`0xc0089a01..0xc0089a06`, `0xc0089a08`, `0xc0089a09`, `0xc0089a28`,
`0xc0089a29` (and `0xc0189a07`).

### 8-byte main IOCTLs → `av_crtc_helper_7140`

`0xc0089a13..0xc0089a15`, `0xc0089a1a`, `0xc0089a1c`, `0xc0089a1d`.

### 8-byte main IOCTLs → other

`0xc0089a1e` → `av_state_query`
`0xc0089a1f` → `av_crtc_helper_7b60`
`0xc0089a21` → `av_verify_timing`

### 12/16-byte mode-set IOCTLs → `av_crtc_helper_7140`

`0xc00C9a16`, `0xc00C9a17`, `0xc0109a0d`, `0xc0109a0e..0c`, `0xc0109a11`,
`0xc0109a12`.

### 16-byte verify-timing IOCTLs → `av_verify_timing`

`0xc0109a0d` (some), `0xc0109a10..11`, `0xc0109a12`.

### 24-byte → `av_set_output_mode`

`0xc0189a0f`, `0xc0189a10`, `0xc0189a22`.

### 24-byte → `av_crtc_handler`

`0xc0189a07`.

### **96-byte MEGA-IOCTL `0xc0609a23` — `update_info` (mode-set + HDR set)**

This is the comprehensive AV mode-set call. Validates 22 fields:

| Field | Offset | Constraint | Likely meaning |
|---|---|---|---|
| `[0]` | `+0x00` | non-NULL pointer | Out: result code buffer |
| `[2]` | `+0x08` | ptr (non-NULL) | Out: ? |
| `[10]` | `+0x28` | ptr (non-NULL) | Out: ? |
| `[14]` | `+0x38` | ptr (non-NULL) | Out: ? |
| `[16]` | `+0x40` | ptr (non-NULL) | Out: HDR transition flag |
| `[20]` | `+0x50` | ptr (non-NULL) | Out: timing fields? |
| `[2].u32` | `+0x08` | ≤ 0xC (= 12) | **output_mode_id** |
| `[3].u32` | `+0x0C` | ≤ 1 | output flag |
| `[6].u32` | `+0x18` | ≤ 3 | bit depth? |
| `[7].u32` | `+0x1C` | ≤ 4 | **transfer function** (gamma curve) |
| `[8].u32` | `+0x20` | ∈ {2, 0xC, 0x12, 0x18, 0x24} | pixel format (RGB/YCbCr 4:2:0/4:2:2/4:4:4) |
| `[12].u32` | `+0x30` | ≤ 0x7F | bit-flags |
| `[18].u32` | `+0x48` | ≤ 2 | display mode (passthrough/scale) |
| `[19].u32` | `+0x4C` | ≤ 0x34 (52) | **output_mode_id_extended** |
| `[22].u32` | `+0x58` | ≤ 2 | HDR enable level |

Then reads 0x58 (88) bytes of **detail-timing parameters** at
`copyin(arg[0], &local_90, 0x58)` and runs `update_timing_params`.

## **🎨 HDR / colorspace transition table** (from printk strings)

The `update_info` IOCTL detects colorspace transitions and prints debug
messages. Decoded mapping (the `DAT_caafc49c` variable):

| ID | Meaning |
|---|---|
| `0` | `srgb` (PC RGB, full range) |
| `1` | `cergb` (CE-RGB / BT.709 / sRGB CEA) |
| `2` | `yccbt2020` (YCbCr BT.2020 SDR) |
| `3` | `rgbbt2020` (RGB BT.2020 SDR) |
| `4` | `yccbt2020` (alias / variant) |
| `5` | `rgbbt2020` (alias / variant) |
| `6` | `yccbt2020_hdr10` (HDR10 YCbCr BT.2020) |
| `7` | `rgbbt2020_hdr10` (HDR10 RGB BT.2020) |
| `8` | `yccbt2020_hdr10` (alias / variant) |
| `9` | `rgbbt2020_hdr10` (alias / variant) |
| `0xC` | `cergb_hdr10` (HDR10 in BT.709 — rare combo) |

Transitions handled "without link training":
- `0 → 1` and `1 → 0` (sRGB ↔ CE-RGB) — same primaries, just range
- `2 ↔ 4` (YCC BT.2020 variants)
- `3 ↔ 5` (RGB BT.2020 variants)
- `8 ↔ 6` (HDR10 YCC variants)
- `9 ↔ 7` (HDR10 RGB variants)
- `2 ↔ 6` (YCC BT.2020 SDR ↔ HDR10) — same colorspace, gamma changes
- `3 ↔ 7` (RGB BT.2020 SDR ↔ HDR10)
- `0/1 ↔ 0xC` (sRGB/CE-RGB ↔ cergb_hdr10)

Transitions REQUIRING link training: anything else (colorspace
primaries change).

## State variables

| Symbol | Address | Purpose |
|---|---|---|
| `av_lock` | `DAT_caafc4d0` | Main lock |
| `av_power_state` | `DAT_caafc4c8` | Current power state (set via `0xc0049a24`) |
| `av_power_state_prev` | `DAT_caafc4cc` | Previous power state |
| `av_need_link_train` | `DAT_caafc4f0` | 1 = set_mode_soc was called, next set_mode does LT |
| `av_lt_flag` | `DAT_caafc4f4` | Working "needs LT" flag |
| `av_current_mode_id` | `DAT_caafc470` | Current output mode ID |
| `av_current_pix_format` | `DAT_caafc49c` | Current colorspace ID |
| `av_current_transfer_fn` | `DAT_caafc4b8` | Current gamma curve |
| `av_current_bits` | `DAT_caafc4b0` | Bit-depth flags |
| `av_current_output_mode_ext` | `DAT_caafc510` | Extended output mode |

## Set-mode flow (state machine)

```
                ┌─────────────────────────┐
                │  av_power_state == 1 ?  │
                │  (av_power_state_prev   │
                │       == 0)?            │
                └────────────┬────────────┘
                             │ yes
                             ↓
                ┌─────────────────────────┐
                │ av_need_link_train == 1?│
                └────────────┬────────────┘
                             │ yes
                             ↓
                   set_mode_soc path:
                   av_lt_flag = 1
                   av_need_link_train = 0
                   printk "set_mode_soc is called"
                             │
                             ↓
                ┌─────────────────────────┐
                │  All 14 timing fields   │
                │  match previous?        │
                └────────────┬────────────┘
                  yes        │       no
                   │         │       │
            same-mode path   │   different timings → 
            check av_lt_flag │   ┌──────────────────┐
                             │   │ Validate cspace  │
                             │   │ transition:      │
                             │   │ - Compatible?    │
                             │   │   → no LT needed │
                             │   │ - Incompatible?  │
                             │   │   → LT required  │
                             │   └──────────────────┘
                             │           │
                             ↓           ↓
                       Apply mode, copyout flags
```

## Open questions / TODOs

1. **Crtc commands** — decode all `av_crtc_handler` cmds (0xc0089a01..06,
   28, 29). These probably set per-CRTC params: position, size, rotation.
2. **Output mode ID table** — `0..0xC` for one set, `0..0x34` for the
   "extended" set. Likely 1080p/720p/4K/various refresh rates. Find
   the data table.
3. **Pixel format codes** — {2, 0xC, 0x12, 0x18, 0x24}. Likely
   ARGB8888 / RGB565 / NV12 / etc. Find usage in `update_timing_params`.
4. **Bit depth** field `[6]` (0..3) — probably 8/10/12 bit per
   channel.

## Linux equivalent

| Sony av_control | Linux mainline |
|---|---|
| `update_info` IOCTL (mode + HDR set) | `DRM_IOCTL_MODE_ATOMIC` with HDR_OUTPUT_METADATA property |
| Colorspace ID `0..0xC` | DRM `COLOR_ENCODING` + `COLOR_RANGE` properties |
| HDR transfer fn | DRM `HDR_OUTPUT_METADATA` property (CEA-861-G EOTF) |
| `av_need_link_train` | Implicit in `drm_atomic_helper` (sets `DRM_MODE_SET_CRTC_DPMS` and lets DRM driver decide) |
| Per-CRTC commands | `drm_atomic_state` per `drm_crtc` |

For our Linux on PS4: once `amdgpu` probes successfully, DRM handles
all of this. We don't need to port `av_control` — but for full HDR
output we'd want to ensure our ps4_bridge.c properly advertises HDR
support via DRM connector EDID parsing.

## Connections to other rooms

- **hdmi** room: av_control's mode-set ultimately flows down to the
  `hdmi` module's IOCTL surface (`0x8D` magic).
- **dce** room: per-CRTC commands map to `dce_ctx`'s flip queue.
- **scanin** sub-room: scanout buffer config is part of mode-set.
