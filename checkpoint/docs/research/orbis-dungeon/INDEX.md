# 🏰 Orbis Kernel Dungeon Map

**Target binary:** `orbis-12.02.elf` (md5 `13b07d9abb21f12ed5506903a44159e1`)
**Image base:** `0xffffffffc839c000`
**Memory size:** ~55 MB (57,730,312 bytes)
**Function count:** 19,714
**Symbol count:** 93,954
**Compiler:** GCC (FreeBSD/Orbis x86_64)

Source paths embedded in strings: `W:\Build\J02688428\sys\internal\modules\<module>\`

This dungeon is the result of Sony's kernel build pipeline.
We're systematically mapping every "room" (subsystem / kernel module).

---

## 🗺️ Floor plan

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ FLOOR 0 — ENTRANCE HALL                                                     │
│   entry @ c8406410 → setup_kernel_environment @ c85087a0 → mi_startup       │
│   (see ENTRANCE.md)                                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 1 — KERNEL CORE / BOOTSTRAP                                            │
│   SYSINIT chain, BTX bootloader handoff, GDT/IDT/TSS setup, EFER MSRs,       │
│   per-CPU GS_OFFSET layout, processor identification (AMD vendor 0x1022).    │
│   No source paths — this is the kernel's own infrastructure.                 │
│   (see CORE.md)  [TODO]                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 2 — GRAPHICS / DISPLAY (sys/internal/modules/gc + dce + ...)           │
│   ┌── gc        — Graphics Compositor (vmid mgmt, samu, vbios)               │
│   │              [partially mapped during UVD dig — see                       │
│   │               2026-05-11-ghidra-uvd-dungeon-map.md +                      │
│   │               2026-05-12-uvd-pre-init-dig.md]                             │
│   ├── dbggc     — Debug GC (gpu exception trapping)                          │
│   ├── dce       — Display Controller Engine (scanin/flip/ih)                 │
│   ├── av_control— A/V control (crtc, main pipeline)                          │
│   ├── hdmi      — HDMI driver                                                │
│   └── screenshot— Screen capture                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 3 — VIDEO CODECS                                                       │
│   ┌── uvd       — UVD decoder (PAUSED — see UVD_BRINGUP_MAP.md)              │
│   └── vce       — VCE encoder (untouched)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 4 — AUDIO                                                              │
│   ┌── audioout  — HD audio + USB audio + sound/pcm channel mgr               │
│   ├── ajm       — Audio JaggedMix service (Codec/BatchMisc/Memory/ACP)       │
│   └── s3da      — 3D audio engine                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 5 — STORAGE / DMA                                                      │
│   ┌── sdma      — System DMA (kreader, hwdep, mini, context)                 │
│   └── mbus      — Message bus (kmod + event)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 6 — INPUT (HID)                                                        │
│   ┌── hid       — Generic HID + USB HID + ujedi_dfu (controller fw update)   │
│   ├── ctrlp     — Control pad                                                │
│   └── bluetooth_hid — BT HID glue                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 7 — WIRELESS                                                           │
│   ┌── wlan      — WLAN (trooper / torus MediaTek MT76 variants)              │
│   ├── bt        — Bluetooth (sys/driver/gatt)                                │
│   └── wlanbt    — Combined chip glue                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 8 — CAMERA / VR / HMD                                                  │
│   ┌── camera    — PlayStation Camera (luke = chip name)                      │
│   ├── hmd       — Head-mounted display (PSVR)                                │
│   └── hmddfu    — PSVR firmware update                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 9 — SECURITY (sbl/*) — THE LOCKED VAULT                                │
│   ┌── sbl/driver       (handler.c is the SAMU mailbox, gpuvm.c)              │
│   ├── sbl/service      (15+ subservices: ccp, np, pfs, key, sysveri, …)     │
│   ├── sbl/sm_service   (security manager service)                            │
│   ├── sbl/srtc         (secure RTC)                                          │
│   ├── sbl/pup_update   (firmware update path)                                │
│   ├── sbl/eipk_addsign (entry-package signing)                               │
│   ├── sbl/devact       (device activation)                                   │
│   ├── sbl/pltauth      (platform auth)                                       │
│   ├── sbl/authmgr      (auth manager — pltauth_sm, secureclock_sm, eekc_mgr) │
│   ├── sbl/vtrm         (volatile trusted ram — two_bank)                     │
│   ├── sbl/rng          (RNG driver)                                          │
│   ├── sbl/idata        (Sony's ID-data area)                                 │
│   ├── sbl/usb_dongle   (USB jig?)                                            │
│   ├── sbl/qafutkn      (QA / factory token)                                  │
│   ├── sbl/npdrm        (Network platform DRM)                                │
│   ├── sbl/zlib         (zlib in kernel, signed-only)                         │
│   └── sbl/lvp_config   (Liverpool config)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│ FLOOR 10 — SYSTEM SERVICES                                                   │
│   ┌── regmgr    — Registry manager (preferences storage)                     │
│   ├── ipmimgr   — Inter-process-messaging manager                            │
│   ├── sdbgp     — System debug print                                         │
│   └── mas       — Mass storage? (HMD-related?)                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Room status tracker

Legend: 🗝️ unexplored · 🔍 partial · ✅ fully mapped · ⚠️ blocked / paused

### Floor 0–1: Boot / Core
| Room | Status | File |
|---|---|---|
| ENTRANCE | ✅ | [ENTRANCE.md](ENTRANCE.md) |
| CORE | 🗝️ | (boot finish: SYSINIT chain, EFER, GDT/IDT/TSS, GS_OFFSET) |

### Floor 2: Graphics / Display
| Room | Status | File |
|---|---|---|
| gc | 🔍 | partial via UVD dig — `2026-05-11-ghidra-uvd-dungeon-map.md`, `2026-05-12-uvd-pre-init-dig.md` |
| dbggc | 🗝️ | rooms/dbggc.md |
| dce | 🔍 first-pass | rooms/dce.md |
| av_control | 🔍 first-pass | rooms/av_control.md |
| hdmi | 🔍 first-pass ⭐ | rooms/hdmi.md (**high-value for Linux DRM port**) |
| screenshot | 🗝️ | rooms/screenshot.md |

### Floor 3: Video codecs
| Room | Status | File |
|---|---|---|
| uvd | ⚠️ paused | `../UVD_BRINGUP_MAP.md`, `../2026-05-12-a17-result.md` |
| vce | 🔍 first-pass | rooms/vce.md |

### Floor 4: Audio
| Room | Status | File |
|---|---|---|
| audioout | 🔍 first-pass | rooms/audioout.md |
| ajm | 🗝️ | rooms/ajm.md |
| s3da | 🗝️ | rooms/s3da.md |

### Floor 5: Storage / DMA
| Room | Status | File |
|---|---|---|
| sdma | 🔍 first-pass | rooms/sdma.md |
| mbus | 🔍 first-pass | rooms/mbus.md |

### Floor 6: Input
| Room | Status | File |
|---|---|---|
| hid | 🗝️ | rooms/hid.md |
| ctrlp | 🗝️ | rooms/ctrlp.md |
| bluetooth_hid | 🗝️ | rooms/bluetooth_hid.md |

### Floor 7: Wireless
| Room | Status | File |
|---|---|---|
| wlan | 🗝️ | rooms/wlan.md |
| bt | 🗝️ | rooms/bt.md |
| wlanbt | 🗝️ | rooms/wlanbt.md |

### Floor 8: Camera / VR
| Room | Status | File |
|---|---|---|
| camera | 🗝️ | rooms/camera.md |
| hmd | 🗝️ | rooms/hmd.md |
| hmddfu | 🗝️ | rooms/hmddfu.md |

### Floor 9: Security (LOCKED VAULT)
| Room | Status | File |
|---|---|---|
| sbl/driver | 🔍 | partial — SAMU mailbox protocol decoded in UVD dig |
| sbl/service | 🗝️ | rooms/sbl-service.md |
| sbl/sm_service | 🗝️ | rooms/sbl-sm_service.md |
| sbl/srtc | 🗝️ | rooms/sbl-srtc.md |
| sbl/pup_update | 🗝️ | rooms/sbl-pup_update.md |
| sbl/eipk_addsign | 🗝️ | rooms/sbl-eipk_addsign.md |
| sbl/devact | 🗝️ | rooms/sbl-devact.md |
| sbl/pltauth | 🗝️ | rooms/sbl-pltauth.md |
| sbl/authmgr | 🗝️ | rooms/sbl-authmgr.md |
| sbl/vtrm | 🗝️ | rooms/sbl-vtrm.md |
| sbl/rng | 🗝️ | rooms/sbl-rng.md |
| sbl/idata | 🗝️ | rooms/sbl-idata.md |
| sbl/usb_dongle | 🗝️ | rooms/sbl-usb_dongle.md |
| sbl/qafutkn | 🗝️ | rooms/sbl-qafutkn.md |
| sbl/npdrm | 🗝️ | rooms/sbl-npdrm.md |
| sbl/zlib | 🗝️ | rooms/sbl-zlib.md |
| sbl/lvp_config | 🗝️ | rooms/sbl-lvp_config.md |

### Floor 10: System services
| Room | Status | File |
|---|---|---|
| regmgr | 🔍 first-pass | rooms/regmgr.md |
| ipmimgr | 🔍 first-pass | rooms/ipmimgr.md |
| sdbgp | 🗝️ | rooms/sdbgp.md |
| mas | 🗝️ | rooms/mas.md |

---

## Methodology

Each room file follows this template:

```md
# Room: <module>

**Source:** `sys/internal/modules/<module>/...`
**Address range:** `0x...` to `0x...` (heuristic from xrefs)
**Key strings:** ...
**Top-level entry points:** ...

## Why it matters for Linux on PS4
(Specifically: what Linux can / can't replicate, what mainline drivers it
would map to, anything Sony does that we should learn from.)

## Function map
| Sony function | Address | Linux equivalent | Notes |
|---|---|---|---|

## IPC / IOCTL surface
(External entry points: syscalls, ioctls, sysctls.)

## State machine
(For complex modules — what each state means and transitions.)

## Open questions / TODOs
```

## Progress notes

- 2026-05-12 iter 9: + ipmimgr first-pass — Inter-Process Messaging
  Manager. PS4's main IPC backbone (Binder/D-Bus equivalent).
  14 sub-files. syscallCreateServer flow decoded — server registry,
  pending connect-request matching, vthread/kid lifecycle. Useful for
  understanding cross-module userspace flow but no Linux port needed.
- 2026-05-12 iter 8: + audioout first-pass — Audio Output stack.
  3-layer: uaudio (USB) / sound/pcm (vanilla FreeBSD) / snd_hda/hdac
  (Sony-quirked). Stock FreeBSD code mostly. Linux's snd_hda_intel
  already handles PCI 00:01.1 HDMI audio per A17 boot log. No port
  work needed; deeper dig into hdac.c quirks deferred.
- 2026-05-12 iter 7: + vce first-pass — Video Compression Engine (encoder).
  Sister to UVD. 9 IP block func pointers (amdgpu-style), GFX reg
  0xf802 bits 0+2 = VCE clock enable. Chip family signature 0x740f00 =
  Baikal. State struct 0x158 bytes. Mutex names: "vce lock", "vce ih
  lock", "vce context memory". TBD: vce_hw_init_baikal deep dive.
- 2026-05-12 iter 6: + av_control first-pass — AV mode + HDR controller.
  IOCTL magic 0x9A, ~30 commands. 96-byte mega-IOCTL `update_info`
  decoded with 22 fields. Bonus: full Sony HDR colorspace table
  extracted from printk strings (IDs 0..0xC: srgb/cergb/yccbt2020/
  rgbbt2020/HDR10 variants). Link-training detection logic mapped.
- 2026-05-12 iter 5: + dce first-pass — Display Controller Engine.
  Per-context flip queue, IH packet dispatcher confirms standard AMD
  layout (client_id<<48 | src_id<<40 | data). Mainline amdgpu DC code
  applies. ih.c register/unregister functions identified.
- 2026-05-12 iter 4: + hdmi first-pass ⭐ — Sony's HDMI bridge controller.
  Magic 0x8D, ~30 IOCTLs decoded, 7-state event-driven state machine
  via SceHdmiEvent kthread, HDCP/EDID/mode-set/audio handlers identified.
  HIGH VALUE: directly informs our ps4_bridge.c work.
- 2026-05-12 iter 3: + sdma first-pass — System DMA service. IH tasklet
  with 16-slot ring, packet types 0xF3 (heartbeat) / 0xE0 (completion).
  Three completion sub-types (mutex/notify/condvar). Submit packet
  format decoded: opcode + queue ID + src addr + 20-bit length.
- 2026-05-12 iter 2: + mbus first-pass — Sony's AV hotplug event router.
  event_id 9 = HDMI; tracks deviceId counter; 3ms debounce; suspend/resume
  eventhandler hooks. Confirmed Sony has an HDMI state machine we'll
  want to mirror for our DRM bridge work.
- 2026-05-12 iter 1: Created dungeon map. Mapped ENTRANCE (boot path),
  regmgr first-pass. 26+ Floor 2-10 rooms still to explore.
  Partial UVD + gc + sbl/driver mappings exist from prior UVD dig
  (see `../orbis-kernel/` and `../UVD_BRINGUP_MAP.md`).
- Loop runner: `/loop` command, dynamic mode, self-paced. Resumes via
  ScheduleWakeup. To force-stop the loop, the user will say "stop loop"
  or send no resume signal.
