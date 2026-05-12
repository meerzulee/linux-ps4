# 🏆 Orbis Kernel Dungeon — Final Summary

**Started:** 2026-05-12 ~01:30
**Completed:** 2026-05-12 ~08:55
**Duration:** ~7 hours of self-paced exploration across 17 iterations
**Binary mapped:** `orbis-12.02.elf` (md5 `13b07d9abb21f12ed5506903a44159e1`)
**Total source files documented:** 130+ (out of 157 unique embedded paths)
**Function ranges identified:** ~500+ across 10 floors

This is the wrap-up doc. Read [INDEX.md](INDEX.md) for the room-by-room
status table, [ENTRANCE.md](ENTRANCE.md) for the boot path, and the
individual `rooms/*.md` files for per-module details.

---

## What we mapped

```
FLOOR 0  ENTRANCE       ✅  Boot chain (entry → setup → mi_startup)
FLOOR 1  CORE           🗝️  Standard FreeBSD 9 (no Sony mods worth mapping)
FLOOR 2  GRAPHICS       ✅  gc (partial) + dbggc + dce + av_control + hdmi + screenshot
FLOOR 3  VIDEO CODECS   ⚠️  uvd PAUSED + vce mapped
FLOOR 4  AUDIO          ✅  audioout + ajm + s3da
FLOOR 5  STORAGE/DMA    ✅  sdma + mbus
FLOOR 6  INPUT          ✅  hid + ctrlp + bluetooth_hid
FLOOR 7  WIRELESS       ✅  wlan + bt + wlanbt (MT76xx confirmed)
FLOOR 8  CAMERA/VR      ✅  camera + hmd + hmddfu + mas
FLOOR 9  SECURITY       ✅  sbl/* (4 sub-rooms, ~46 files)
FLOOR 10 SYSTEM SVCS    ✅  regmgr + ipmimgr + sdbgp
```

🔓 **The LOCKED VAULT (`sbl/*`) is fully mapped at first-pass.**

---

## Top 10 highest-value findings

### 1. ⭐ The UVD blocker is real and structural (`sbl/driver` room)

The SAMU runs Sony's signed `secure_kernel.elf`, holds exclusive
SMU access (registers locked from CPU), and the only SMU programming
path is `sceSblDriverWriteSmuIx` via the SAMU mailbox at GPU MMIO
`0x22070..0x2207c`. Linux has no SBL driver → no SMU programming →
UVD VCPU stuck waiting for chip state we can't replicate. This
matches our 17-iteration UVD bring-up postmortem exactly.

**Path forward (if anyone wants to attempt):** weeks-months of work
to:
1. Port handler.c mailbox protocol to Linux kernel
2. Add ioctl/sysfs surface for SMU read/write
3. amdgpu calls our SBL driver to set UVD clocks

### 2. ⭐ HDMI bridge bring-up sequence decoded (`hdmi` room)

Sony's `hdmi.c` has a complete IOCTL surface (magic `0x8D`, ~30 cmds)
and a 7-state event-driven state machine via `SceHdmiEvent` kthread.
This DIRECTLY informs our `ps4_bridge.c` work for getting HDMI display
on Linux. Specifically:
- Replicate `hdmi_power_on` register sequence (cmd `0x20008d01`)
- Implement event-type-1 + event-type-3 transitions
- Skip HDCP for Linux (no need)
- Extract Sony's mode timing table for DRM `mode_valid()`

### 3. ⭐ PS4 wireless = MediaTek MT76xx (`wireless` room)

Confirmed via Sony codenames: **TROOPER** (chip) + **TORUS** (USB combo
radio). Mainline Linux `mt76` driver covers this. Port work needed:
1. Add PS4 PCI subsystem IDs to mt7668 match table
2. Add btusb quirks for HCI vendor extensions
3. Extract `trooper.bin` firmware from PUP

Days, not weeks. Straightforward driver port — no RE needed.

### 4. ⭐ HDR colorspace ID table (`av_control` room)

Sony's full pixel-format / colorspace IDs extracted from printk
debug strings:

| ID | Meaning |
|---|---|
| `0` | srgb |
| `1` | cergb (BT.709) |
| `2`/`4` | yccbt2020 (SDR) |
| `3`/`5` | rgbbt2020 (SDR) |
| `6`/`8` | yccbt2020_hdr10 |
| `7`/`9` | rgbbt2020_hdr10 |
| `0xC` | cergb_hdr10 |

Linux DRM `COLOR_ENCODING` + `HDR_OUTPUT_METADATA` properties map
directly. Useful when we eventually want HDR via DRM.

### 5. ⭐ DS4 anti-counterfeit auth decoded (`hid-input` room)

`SceHidAuth` kthread runs a 6-state RSA-1024 + ECDSA-with-SHA
challenge-response for connecting controllers. Auto-trust IDs
hardcoded for genuine DS4 v1/v2; 14-entry sorted whitelist for
licensed 3rd-party. After 3 failures: terminal lock state.

Linux skips this entirely — `hid-sony` / `hid-playstation` work without
auth.

### 6. AMD CCP (Crypto Co-Processor) is the same hardware (`sbl/service` room)

Sony's `ccp/*` subdirectory wraps the AMD PSP Crypto CoProcessor.
Mainline Linux drives the same hardware via `drivers/crypto/ccp/`.
So we get hardware AES/SHA acceleration for free — no port work.

### 7. PS4 HDD encryption explained (`sbl/authmgr` room)

`_sceSblAuthMgrSmDriveData` + `_sceSblAuthMgrSmDriveGetId2` confirm:
PS4's internal SATA HDD is encrypted with console-specific keys held
by SAMU. Linux can SEE the SATA device but partitions are opaque
without SBL access. This explains WHY our Linux setup uses external
USB rootfs (`root=LABEL=psxitarch`).

### 8. Sony's IH packet layout matches mainline AMD (`dce` room)

The `client_id<<48 | src_id<<40 | data` packet layout that mainline
amdgpu's `amdgpu_ih.c` parses is identical to what Sony's `ih.c`
parses. **Validates our prior UVD IH debug interpretation** (the
`0x55564400 = 'UVD'` client_id we saw was correct).

### 9. mbus = HDMI hotplug event router (`mbus` room)

Sony's mbus is specifically the AV-device hotplug event bus.
`event_id 9` = HDMI connect/disconnect with deviceId counter. 3 ms
debounce. Subscribers get `deviceId<<8 | state` payload. Tells us
Sony's HDMI debounce timing for our bridge driver.

### 10. Sony Liverpool chip family = `0x740f00` (`vce` room)

`vce_hw_init` has `if (get_chip_family() & 0xffffff80 == 0x740f00)`
to dispatch Baikal vs Gladius. Useful magic number for cross-checking
against UVD's chip-variant-1 dispatch.

---

## Sony codenames extracted

| Codename | Hardware |
|---|---|
| **trooper** | MT76xx WiFi/BT chip |
| **torus** | USB BT/WLAN combo radio |
| **ujedi** | DualShock 4 controller |
| **luke** | PS Camera (CUH-ZEY1/2 stereo IR) |
| **baikal** | Liverpool SoC (PS4 Slim, family `0x740f00`) |
| **gladius** | Liverpool variant (PS4 Pro?) |

Pattern: a mix of Star Wars + general fantasy / sword-and-sorcery
codenames. Sony loves codenames.

---

## What Linux on PS4 still needs (ranked by impact)

🔥 **CRITICAL** (blocks basic usability):
1. **HDMI display via `ps4_bridge.c`** — informed by `hdmi` room
2. **MT76xx WiFi+BT driver port** — informed by `wireless` room
3. **Ethernet (sky2 doesn't recognize Baikal GbE)** — not in dungeon, separate work

🟡 **NICE-TO-HAVE** (improves experience):
4. **UVD soft-fail (A18)** — make uvd_v4_2_hw_init always return 0 so
   amdgpu probe doesn't die
5. **HDR support via DRM** — using av_control's colorspace table

🟢 **LOW PRIORITY** (specialized use cases):
6. PSVR support — niche, OpenHMD covers it
7. PS Camera as webcam — works as standard UVC
8. UVD/VCE hardware decode — structurally blocked without SBL port
9. DS4 over Bluetooth pairing — works via standard `bluetoothctl`
10. PS4 internal HDD reading — structurally blocked without SBL port

---

## Things Linux DOESN'T need from this map

| Sony subsystem | Why not relevant |
|---|---|
| `regmgr` (registry) | Linux has its own config storage |
| `ipmimgr` (IPC) | D-Bus / Wayland / Unix sockets cover it |
| `sbl/service/*` (DRM/PSN/save data) | We don't run Sony content |
| `sbl/authmgr` (SELF verifier) | We don't run signed binaries |
| `sbl/leaves/*` (factory tokens, npdrm, etc.) | All PSN/factory-specific |
| `ajm` (multi-codec audio) | FFmpeg covers it |
| `s3da` (3D audio) | OpenAL Soft / PipeWire cover it |
| `screenshot` | DRM dumb buffer + scrot cover it |
| `dbggc` (GPU debug) | Mainline amdgpu has equivalent |
| `audioout` (HD Audio) | snd_hda_intel covers it (already loads on Linux) |

---

## Methodology that worked

For anyone doing similar dungeon exploration:

1. **Source paths embedded as strings** — search for
   `internal\\modules\\` to enumerate all top-level modules. Worked
   well: 157 unique paths, 27 top-level modules.
2. **String xrefs to find function ranges** — the printk strings in
   each `.c` file are referenced from functions in that file, giving
   approximate address ranges per source.
3. **Combine related modules into single rooms** — saves time and
   makes the doc more readable. e.g., hid + ctrlp + bluetooth_hid
   into one `hid-input.md`.
4. **Compute exclusion table early** — knowing what's NOT useful for
   Linux helps prioritize. Most of SBL fell into "not relevant" once
   the structure was clear.
5. **Cross-reference findings** — mbus's HDMI debounce timing
   informed hdmi's state machine; vce's chip family `0x740f00` matches
   uvd's variant-1 dispatch; etc.

---

## Iteration log

| Iter | Room(s) | Commit |
|---|---|---|
| 0 | INDEX + ENTRANCE | `ee9ae95` |
| 1 | regmgr | `ee9ae95` |
| 2 | mbus | `1e99186` |
| 3 | sdma | `9f18679` |
| 4 | hdmi ⭐ | `fb07e5b` |
| 5 | dce | `1f5b3aa` |
| 6 | av_control | `a4e330f` |
| 7 | vce | `830b6a4` |
| 8 | audioout | `6b6561b` |
| 9 | ipmimgr | `d189710` |
| 10 | hid + ctrlp + bluetooth_hid ⭐ | `b692b3d` |
| 11 | wlan + bt + wlanbt ⭐ | `718b34d` |
| 12 | camera + hmd + hmddfu + mas | `002a61c` |
| 13 | sbl/driver ⭐ | `89dea08` |
| 14 | sbl/service (20 files) | `9d8ba1f` |
| 15 | sbl/authmgr + sm_service (10 files) | `f3428e9` |
| 16 | sbl/leaves (13 files) 🔓 | `f390528` |
| 17 | leaves (final 6) + this SUMMARY | this commit |

---

## Where to go from here

This dungeon map serves as a **reference catalog** for future Sony
kernel exploration. When the user has a specific feature question,
the relevant room has the function addresses ready for a deeper dig.

For our Linux-on-PS4 port specifically, the highest-value next steps
(not in this dungeon's scope, but informed by it):

1. **Get HDMI working** — replicate `hdmi.c`'s power-on + event-type-1/3
   transitions in our `ps4_bridge.c`.
2. **Port mt7668 WiFi/BT** — straightforward mainline driver port.
3. **A18 UVD soft-fail** — let amdgpu probe succeed even if UVD fails.

After those three: the system is fully usable. Everything else (HDR,
hardware decode, PSVR) is gravy.

🐉 **Dungeon cleared.** 🏰
