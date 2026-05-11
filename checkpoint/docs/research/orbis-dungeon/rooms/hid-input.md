# Floor 6 trio: hid + ctrlp + bluetooth_hid

This room maps three input-related modules together since they
interconnect tightly.

## Source paths

**hid:**
- `sys/internal/modules/hid/usb/ujedi_dfu.c` @ string `c8e785c9` (DS4 firmware update)
- `sys/internal/modules/hid/usb/usb_hid.c` @ string `c8e78692` (USB HID class)
- `sys/internal/modules/hid/hid_utility.c` @ string `c8e78f3a`
- `sys/internal/modules/hid/hid_application_authentication.c` @ string `c8e794eb` (**DS4 auth**)

**ctrlp:**
- `sys/internal/modules/ctrlp/ctrlp.c` @ string `c8e8b86f`

**bluetooth_hid:**
- `sys/internal/modules/bluetooth_hid/bluetooth_hid.c` @ string `c8ed1315`

**Function ranges:**
- `hid/`: ~`c8971000..c8980000`
- `ctrlp/`: ~`c89f2000..c89f6000`
- `bluetooth_hid/`: TBD (no fn xrefs decoded yet)

## What this room does

PS4 controller (DualShock 4 + 3rd-party + special accessories) input
handling. Three layers:

```
┌────────────────────────────────────────────┐
│ ctrlp (Control Pad)                        │ ctrlp.c
│   - Touchpad, motion, lightbar             │
│   - Battery state, vibration               │
│   - Userspace IOCTL interface              │
├────────────────────────────────────────────┤
│ hid_application_authentication             │ hid_application_authentication.c
│   - RSA + ECDSA + SHA challenge-response   │
│   - Per-controller whitelist               │
│   - Anti-counterfeit gate                  │
├────────────────────────────────────────────┤
│ usb_hid + bluetooth_hid (transport layer)  │ usb_hid.c, bluetooth_hid.c
│   - USB HID class                          │
│   - BT HID-over-L2CAP                      │
│   - Standard FreeBSD glue                  │
└────────────────────────────────────────────┘
```

## Why it matters for Linux on PS4

🔍 **Mostly works on Linux** — DualShock 4 has been supported by
mainline Linux's `hid-sony` / `hid-playstation` since kernel 4.10+:

| PS4 Linux scenario | Status |
|---|---|
| DS4 over USB | ✅ Works via `hid-sony` mainline |
| DS4 over Bluetooth | ✅ Works via `hid-sony` once paired |
| DS4 controller pairing | ⚠️ Needs `bluetoothctl` flow; PS4-stored pairings don't transfer |
| Touchpad multitouch | ✅ Works via `hid-sony` |
| Lightbar control | ✅ Works via sysfs `leds/sony*` |
| Vibration | ✅ Works via `evdev` rumble |
| Built-in speaker | ✅ Works via `snd_usb_audio` |
| Headphone jack (controller) | ✅ Works via `snd_usb_audio` |
| Motion (gyro/accel) | ✅ Works via `iio` subsystem |
| Battery indicator | ✅ Works via `power_supply` class |

So the Sony HID stack is **largely irrelevant to porting**. Linux's
mainline drivers handle everything.

The interesting finding from this dig is the **anti-counterfeit
authentication thread** — useful to know about because it explains
why some 3rd-party controllers don't work on PS4 firmware but DO
work on Linux (Linux skips the auth entirely).

## Function map (first-pass)

### `hid_application_authentication.c` (the big one)

| Sony function | Address | Purpose |
|---|---|---|
| `hid_auth_helper_f480` | `c897f480` | wrapper for hid_auth from hid_utility.c |
| `hid_auth_helper_d930` | `c897d930` | (init / queue helper) |
| `hid_auth_helper_da10` | `c897da10` | (param-3 helper) |
| `hid_auth_helper_dae0` | `c897dae0` | (param-3 helper) |
| **`hidAuthThreadMain`** | `c897dcf0` | **SceHidAuth kthread** — runs the 6-state challenge-response state machine |
| `hid_auth_get_feature` | `c8594c70` | HID get_feature (memcpy-style read from device) |
| `hid_auth_set_feature` | `c84b81c0` | HID set_feature (memcpy-style write to device) |

### `hid_utility.c`

| Sony function | Address | Purpose |
|---|---|---|
| `hid_util_helper_f6c0` | `c897f6c0` | Lock/unlock around device access (called from auth thread) |

### `ctrlp.c`

| Sony function | Address | Purpose |
|---|---|---|
| `ctrlp_helper_4190` | `c89f4190` | (init / module helper) |
| `ctrlp_helper_4340` | `c89f4340` | (4 xrefs) |
| `ctrlp_helper_4690` | `c89f4690` | (3 xrefs) |
| `ctrlp_helper_4e70` | `c89f4e70` | (~10 xrefs — major) |
| `ctrlp_helper_55b0` | `c89f55b0` | (3 xrefs) |
| `ctrlp_helper_3050` | `c89f3050` | (~6 xrefs) |
| `ctrlp_helper_3bf0` | `c89f3bf0` | (3 xrefs) |
| `ctrlp_helper_26c0` | `c89f26c0` | (3 xrefs) |
| `ctrlp_helper_2720` | `c89f2720` | (~6 xrefs) |
| `ctrlp_helper_2c10` | `c89f2c10` | (2 xrefs) |
| `ctrlp_helper_2e00` | `c89f2e00` | (3 xrefs) |
| `ctrlp_helper_2fc0` | `c89f2fc0` | (3 xrefs) |

### `usb_hid.c`

| Sony function | Address | Purpose |
|---|---|---|
| `usb_hid_helper_71e90` | `c8971e90` | param-3 handler (PARAM xrefs) |
| `usb_hid_helper_71f70` | `c8971f70` | |
| `usb_hid_helper_72080` | `c8972080` | |
| `usb_hid_helper_72210` | `c8972210` | |
| ... (continues to c8973xxx — many helper fns) | | |

### `ujedi_dfu.c` (DS4 firmware update)

Not yet decoded — `ujedi` is presumably Sony's internal codename for
the DualShock 4 controller (akin to "Liverpool" for Baikal SoC). DFU
= Device Firmware Update. This is the path used when Sony ships a
controller firmware update via PS4 system update.

### `bluetooth_hid.c`

Function range not yet found — single-file module that bridges Sony's
`bt` driver to the `hid_*` modules.

## 🔐 DS4 challenge-response authentication state machine

The `SceHidAuth` kthread (priority 0x208, stack 3 KB) processes auth
requests for connecting HID devices. State variable `DAT_c9dfe54`:

| State | What runs |
|---|---|
| `0` | Read 0x100 bytes feature report (initial identity) |
| `1` | Read 0x210 bytes (vendor ID + product ID + serial). Byte-swap. **Whitelist lookup** in 14-entry sorted table at `DAT_c8e79a30`. Plus auto-trust paths. |
| `2` | Read 0x40-byte feature report (extended ID block) |
| `3` | Reset / clean state |
| `4` | RSA challenge: encrypt 16-byte challenge with 1024-bit RSA key at `DAT_c8e79610`; encrypt 48-byte challenge → 128-byte cipher; SHA over the result (verify=0x40 bytes) |
| `5` | Get response, verify via constant-time XOR (`bVar9 \|= xor[i]`); EC-DSA verify with curve params at `DAT_c8e796e0`; final RSA decrypt with `FUN_c86dd060` (RSA-OAEP probably) |
| `0xD` | **TRUSTED** — passes hardcoded ID match (vid=1 pid=1 + product 0x2bb660 OR 0xa0f35b — "Sony official DS4") |
| `0x15` | **FAILED** — terminal state after 3 failures (`DAT_c9dfe68 < 4`) |

Auto-trust (no challenge needed):
- VID=`1`, PID=`1`, product=`0x2bb660` (= 2,864,224) — likely DS4 v1
- VID=`1`, PID=`1`, product=`0xa0f35b` — likely DS4 v2

Whitelist binary search:
- Table at `DAT_c8e79a30` — 14 entries × 8 bytes (vid:16, pid:16, prod:32 packed)
- Sorted; `bsearch`-style with `(low + high) / 2`
- Hit → mark trusted (set bit 0 of `DAT_c9dfe60`)
- Miss → mark "unknown" (set bit 7 of `DAT_c9dfe60`)

Extended whitelist (configurable):
- Pointer table at `DAT_c8e2b40` — `DAT_c8e2b40` count entries
- Same sorted-binary-search format
- Used for "Sony-licensed 3rd-party controllers" allowed via firmware updates

Crypto primitives used:
- **RSA-1024 encrypt**: `FUN_c86dce30(plaintext, &cipher, len, key, 0x80, sig_buf)`
- **RSA-1024 decrypt**: `FUN_c86dd060(...)` (probably RSA-OAEP)
- **ECDSA verify**: `FUN_c89c1a30(msg, &point, len, &curve_params, &public_key)`
- **ECDSA sign**: `FUN_c83a4f60(...)`
- **SHA-1 / SHA-256**: `FUN_c8594c70` (memcmp-style — actually SHA followed by compare)
- **HMAC-style verify**: `FUN_c8594d40(out, msg, msg_len, key, 0x40)`

Failure handling:
- `DAT_c9dfe68` = consecutive failure count
- After 3 failures: state locks at `0x15` (no more retries until physical
  re-attach)
- Each failure increments + sets `DAT_c9dfe70 = 1` (re-arm flag)

## Open questions / TODOs

1. Decompile `ctrlp.c` IOCTL surface — userspace API for reading
   touchpad / motion / battery.
2. Map `bluetooth_hid.c` — find function range first (no xrefs to
   the source path string yet).
3. Decode the **embedded whitelist table at `DAT_c8e79a30`** — 14
   entries of (vid, pid, prod) for trusted controller models. Would
   tell us which 3rd-party controllers Sony approves.
4. Locate `DAT_c8e79610` — the RSA-1024 public key used for
   challenge encryption. This is part of Sony's anti-counterfeit
   PKI; not generally extractable but interesting to confirm presence.
5. Map `ujedi_dfu.c` (DS4 firmware update). Follows
   `usb_hid` boot quirks for device-firmware-upload (DFU class).

## Linux equivalent

| Sony layer | Linux mainline |
|---|---|
| `usb_hid.c` (USB HID class) | `drivers/hid/usbhid/hid-core.c` |
| `bluetooth_hid.c` (BT HID) | `net/bluetooth/hidp/*.c` |
| `hid_application_authentication.c` | **NONE — Linux skips auth** |
| `ctrlp.c` (touchpad/motion/lightbar) | `drivers/hid/hid-sony.c` (DS4) or `hid-playstation.c` (DS5) |
| `ujedi_dfu.c` (DS4 firmware update) | None upstream; community tools |

For Linux on PS4: **everything works out of the box** with mainline
HID drivers. No port work needed. The only caveat is initial Bluetooth
pairing (PS4-stored pairings don't transfer to Linux's BlueZ) — user
has to re-pair their controllers after switching.

## Connections to other rooms

- **bt**: bluetooth_hid relies on bt module's L2CAP transport.
- **wlanbt**: wlan + bt share a chip on PS4; both serviced by `wlanbt`.
- **sbl**: RSA/ECDSA primitives might call into the SBL ccp service
  for hardware crypto offload.
- **hmd / hmddfu**: PSVR uses similar DFU flow as `ujedi_dfu`.
