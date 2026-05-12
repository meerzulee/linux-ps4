# Room: sbl/leaves — 13 small SBL leaf modules

This room covers the remaining SBL submodules — small single-file
drivers each providing a specific service to the SBL/SAMU subsystem.

## Source paths

| Module | File | String addr |
|---|---|---|
| `srtc` | `srtc/srtc_drv.c` | `c8e8686f` |
| `pup_update` | `pup_update/pup_update.c` | `c8e8713a` |
| `eipk_addsign` | `eipk_addsign/eipk_addsign_drv.c` | `c8e8731a` |
| `devact` | `devact/devact.c` | `c8e87517` |
| `pltauth` | `pltauth/pltauth2.c` | `c8e87945` |
| `vtrm` | `vtrm/two_bank/vtrm_utils.c` | `c8e8995c` |
| `rng` | `rng/rng_drv.c` | `c8e899a3` |
| `idata` | `idata/idata_drv.c` | `c8e89b0b` |
| `usb_dongle` | `usb_dongle/usb_dongle.c` | `c8e89d00` |
| `qafutkn` | `qafutkn/qafutkn_drv.c` | `c8e89e05` |
| `npdrm` | `npdrm/{npdrm_drv,np_drm}.c` | `c8e89ed0`, `c8e89f79` |
| `zlib` | `zlib/zlib_drv.c` | `c8e8a0b8` |
| `lvp_config` | `lvp_config/lvp_config.c` | `c8e8a21f` |

## Module-by-module summary

### 🕒 `srtc` — Secure Real-Time Clock

A separate RTC chip on the southbridge that's TRUSTED — its time
can't be rolled back without leaving evidence. Used for:
- Anti-replay protection on save data
- Time-limited content (movie rentals, demo expiration)
- Activation token freshness

**Linux equivalent:** `drivers/rtc/` covers regular RTCs. Sony's
secure RTC has anti-rollback semantics not present in stock RTCs;
mainline doesn't support that aspect.

### 📦 `pup_update` — PUP firmware update

Validates and applies PS4 system firmware updates (.PUP files).
PUPs contain new SELF binaries for each subsystem, encrypted with
release keys. Verification chain: download .PUP → check Sony's
signature → unpack into per-subsystem updates → for each
`{system_loader,kernel,...}.elf`, call `sceSblAuthMgrAuthHeader`.

**Linux equivalent:** None — Linux uses package managers (pacman,
apt, etc.). PS4's PUP is a monolithic signed image.

### ✍️ `eipk_addsign` — Entry-package signer

Adds entry-point signatures to packages. Used during install/runtime
to bind a package to the current console.

**Linux equivalent:** None.

### 📱 `devact` — Device Activation

Console-side device activation with PSN. Calls
`sceSblAuthMgrPltAuth*` for the actual challenge-response, but
this module provides the higher-level "activate device for account
X" workflow.

**Linux equivalent:** OAuth2 device authorization grant flow.

### 🔐 `pltauth` — Platform Auth (kernel side)

Kernel-side glue for `sceSblAuthMgrPltAuth*` flow. Functions:
- `sceSblPltAuthSmInitialize`
- `sceSblPltAuthSmGenC1`
- `sceSblPltAuthSmVeriR1C2GenR2`
- `sceSblPltAuthSmResult`
- `sceSblPltAuthSmGetKdsMac`

These mirror the authmgr's pltauth_sm.c functions — this is the
"public" kernel-side wrapper that the userspace `devact` daemon calls
into. The authmgr ones are the secure-module entry points.

**Linux equivalent:** None — this is Sony's PSN handshake.

### 🔄 `vtrm` — Volatile Trusted RAM (two-bank)

Anti-rollback storage. The "two_bank" subdirectory implies a
double-buffered scheme (write-then-commit) to guarantee atomicity.
Used for:
- Activation count
- Failed login attempt counter
- Software version (anti-downgrade)
- Seed for time-sensitive nonces

**Linux equivalent:** None — VTRM is a hardware-backed monotonic
counter. TPM 2.0 has similar primitives but very different API.

### 🎲 `rng` — Hardware Random Number Generator

Wrapper around the AMD CCP's hardware RNG. Used for:
- Crypto session keys
- TLS handshake nonces
- Anti-replay tokens

API: `sceSblRngGetRandomNumber` (the only string we found).

**Linux equivalent:** `drivers/char/hw_random/ccp-rng.c` — same
hardware, different driver. Already supported in mainline.

### 💾 `idata` — Per-Console Identity Data

Read-only storage on the console for unique identifiers:
- Console serial number
- PSN account-bound IDs
- Per-console master keys (encrypted)

Burned in at factory. Critical for any per-console binding.

**Linux equivalent:** None — this is a Sony-specific identity vault.
Linux uses `/etc/machine-id` for unique-per-install ID but it's not
hardware-backed.

### 🔌 `usb_dongle` — USB Jig (Factory Mode)

Special USB dongle Sony plugs in at factory to put the console in
service mode. Possibly also used by Sony's repair flow.

**Linux equivalent:** None.

### 🏭 `qafutkn` — QA / Factory Token

Token used during QA testing and factory provisioning. On retail
consoles this should be inert.

**Linux equivalent:** None.

### 🛒 `npdrm` — Network Platform DRM

Two files:
- `npdrm_drv.c` — kernel driver
- `np_drm.c` — DRM logic

Handles per-license decryption for PSN-purchased content. Each
PS4 game .pkg is encrypted with a per-content key, decrypted at
runtime via npdrm + per-account license.

**Linux equivalent:** None — NPDRM is Sony's content protection
system. Linux can play unencrypted content fine (mp4, etc.) but
not Sony-purchased PSN games.

### 🗜️ `zlib` — In-kernel zlib

Sony's zlib in the kernel for decompressing signed payloads (PUP
chunks, save data, etc). Standard zlib library compiled into the
kernel.

**Linux equivalent:** `lib/zlib_*` (already in mainline kernel).

### ⚙️ `lvp_config` — Liverpool Config Blob

Per-chip-revision config blob for the Liverpool/Baikal SoC. Has
silicon-specific tweaks (clock tables, voltage thresholds, etc.)
that vary by chip rev. Loaded at boot.

**Linux equivalent:** None — analogous to BIOS-provided config or
device-tree on ARM. amdgpu's ATOM BIOS interpreter handles some of
this for the GPU side, but the SoC-level Sony Liverpool config is
opaque to mainline.

## Why this room matters for Linux on PS4

🟢 **Almost nothing.** Of the 13 modules:

| Module | Linux relevance |
|---|---|
| `srtc` | None |
| `pup_update` | None (no PS4 updates from Linux) |
| `eipk_addsign` | None |
| `devact` | None |
| `pltauth` | None |
| `vtrm` | None |
| **`rng`** | Indirect — same CCP HW; `drivers/char/hw_random/ccp-rng.c` works |
| `idata` | None |
| `usb_dongle` | None |
| `qafutkn` | None |
| `npdrm` | None |
| **`zlib`** | Indirect — Linux has its own kernel zlib |
| `lvp_config` | None — Linux uses ATOM BIOS for GPU side |

The only Linux-relevant pieces (`rng`, `zlib`) are already covered by
mainline Linux drivers. **No port work needed for any of these.**

## Open questions / TODOs

These modules are all small and mostly opaque (signed-protocol
specific). For future deeper digs (probably never needed for our
Linux port):

1. `pup_update` — full PUP file format. Useful for anyone wanting to
   build custom PUPs.
2. `idata` — per-console identity layout. Useful for anyone wanting
   to spoof or migrate console identity.
3. `vtrm` two-bank scheme — useful for understanding Sony's anti-
   rollback design.

## Linux equivalent summary

| Sony SBL leaf | Linux mainline |
|---|---|
| srtc | `drivers/rtc/` (regular RTC) |
| pup_update | None |
| eipk_addsign | None |
| devact | OAuth2 device auth grant |
| pltauth | None |
| vtrm | TPM 2.0 NV index (loose analogy) |
| rng | `ccp-rng.c` (same hardware!) |
| idata | None — `/etc/machine-id` is closest |
| usb_dongle | None |
| qafutkn | None |
| npdrm | None |
| zlib | `lib/zlib_*` (mainline) |
| lvp_config | ATOM BIOS / DT |

## SBL VAULT MAPPING — STATUS

After 4 iterations into the LOCKED VAULT:
- ✅ `sbl/driver` (iter 13) — handler.c + gpuvm.c
- ✅ `sbl/service` (iter 14) — 20 files
- ✅ `sbl/authmgr + sm_service` (iter 15) — 10 files
- ✅ `sbl/leaves` (iter 16) — 13 files

**Total SBL files documented: ~46.** The full Vault is now mapped
at first-pass level. Any deeper dive would require:
1. Decompiling individual functions in detail (we have the addresses)
2. Specific use case driving the dig (Linux has no immediate need)

## Connections to other rooms

- **sbl/driver**: all leaves use mailbox primitives.
- **sbl/authmgr**: pltauth, devact share the platform-auth flow.
- **sbl/service**: keymgr/cryptmgr provide primitives leaves use.
- **regmgr**: stores activation tokens generated by devact.
- **bt** / **wlan**: use rng for crypto nonces.
