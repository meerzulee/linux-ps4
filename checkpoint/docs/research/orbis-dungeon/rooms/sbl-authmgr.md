# Room: sbl/authmgr + sbl/sm_service — Authentication Manager + Secure Module Service

## Source paths

**sbl/authmgr (7 files):**
- `sys/internal/modules/sbl/authmgr/authmgr.c` @ string `c8e8929c`
- `sys/internal/modules/sbl/authmgr/self_file.c` @ string `c8e882a9`
- `sys/internal/modules/sbl/authmgr/pltauth_sm.c` @ string `c8e8836a`
- `sys/internal/modules/sbl/authmgr/authmgr_secure_module.c` @ string `c8e884f4`
- `sys/internal/modules/sbl/authmgr/secureclock_sm.c` @ string `c8e88bf3`
- `sys/internal/modules/sbl/authmgr/eekc_mgr.c` @ string `c8e895d3`
- `sys/internal/modules/sbl/authmgr/checkup.c` @ string `c8e8961f`

**sbl/sm_service (3 files):**
- `sys/internal/modules/sbl/sm_service/service.c` @ string `c8e85c40`
- `sys/internal/modules/sbl/sm_service/io.c` @ string `c8e85e2a`
- `sys/internal/modules/sbl/sm_service/req.c` @ string `c8e86129`

**Function ranges:**
- `authmgr.c`: ~`c89ddf50..c89df5f0` (large, ~30 functions)
- `sm_service/`: ~`c89cbbc0..c89cbc63` (very small wrapper)

## What this room does

The **AuthMgr (Authentication Manager)** is Sony's anti-piracy gate.
Every signed binary on PS4 (SELF format = Signed ELF) goes through
authmgr before being executed. Three roles:

1. **SELF loader/verifier** (`self_file.c`, `authmgr.c`) — when a
   game .self or system .sprx is loaded, authmgr extracts the
   signature, sends it to SAMU for verification, and gates execution.
2. **Platform Authentication** (`pltauth_sm.c`) — challenge-response
   between the PS4 and Sony's servers, using KDS (Key Distribution
   Server) MACs.
3. **Drive / Activation crypto** (`authmgr_secure_module.c`,
   `eekc_mgr.c`, `checkup.c`, `secureclock_sm.c`) — HDD encryption
   keys, console activation tokens, secure clock.

The **sm_service** subdirectory is the generic "Secure Module" RPC
glue that authmgr (and others) use to call into SAMU functions.

## Why it matters for Linux on PS4

⚠️ **NOT relevant for Linux directly.** Linux doesn't run SELF files
or need to verify signed binaries. We don't have access to PSN
content, don't need device activation, etc.

Useful context only:
1. **Understanding Sony's signing scheme** — if anyone wanted to
   build their own SELF for booting custom code (e.g., Linux
   bootloader signed for Sony's loader to accept), this is where the
   verification happens.
2. **Knowing what's UNAVAILABLE on Linux** — any HDD content
   encrypted by Sony is opaque to us without these keys.

## API surface (54 sceSblAuthMgr* strings extracted)

### Top-level (called from kernel)

| API | What |
|---|---|
| `sceSblAuthMgrInitialize` / `Finalize` | Module lifecycle |
| `sceSblAuthMgrAuthHeader(ehdr, &result)` | Verify SELF header signature |
| `sceSblAuthMgrIsLoadable(path)` | Check if a module path is allowed to load |
| `sceSblAuthMgrLoadSelfBlock` | Load + decrypt one block of an authenticated SELF |
| `sceSblAuthMgrGetSelfInfo` / `GetSelfSegmentInformation` | Query SELF metadata after auth |
| `sceSblAuthMgrCheckSelfHeader` | Header sanity check (pre-auth) |

### Platform auth (from `pltauth_sm.c`)

| API | Stage |
|---|---|
| `sceSblAuthMgrPltAuthGenC1` | Generate challenge C1 |
| `sceSblAuthMgrPltAuthVeriR1C2GenR2` | Verify response R1 + challenge C2, generate R2 |
| `sceSblAuthMgrPltAuthResult` | Get final auth result |
| `sceSblAuthMgrPltAuthGetKdsMac` | Get KDS MAC for follow-up server requests |

This is a **3-pass mutual authentication** (think: TLS handshake) —
PS4 generates challenge C1 → sends to Sony server → server returns
R1+C2 → PS4 verifies R1, generates R2 from C2 → sends R2 → done.
Used during PSN sign-in, store purchases, etc.

### Drive / disk crypto (from `authmgr_secure_module.c`)

| API | What |
|---|---|
| `_sceSblAuthMgrSmStart` / `Finalize` | Open/close secure-module session |
| `_sceSblAuthMgrSmDriveGetId2` | Get HDD identifier (for per-disk binding) |
| `_sceSblAuthMgrSmDriveClearKey` | Wipe HDD encryption keys |
| `_sceSblAuthMgrSmDriveClearSessionKey` | Wipe per-session HDD key |
| `_sceSblAuthMgrSmDriveData` | Bulk drive data crypto operation |

This is what protects PS4's internal HDD. Each console has a unique
key derived from idata + per-disk salt. **Without this we can't read
the encrypted PS4 HDD partitions from Linux.**

### Activation flow (PSN)

| API | What |
|---|---|
| `_sceSblAuthMgrSmGenActRequest` | Generate activation request (sent to PSN) |
| `_sceSblAuthMgrSmGenActHeader` | Activation envelope header |
| `_sceSblAuthMgrSmVerifyActCodeCommon` | Verify activation code from server |
| `_sceSblAuthMgrSmGenPassCodeData` | Generate per-purchase pass-code |
| `_sceSblAuthMgrSmCheckPassCodeData` | Verify pass-code |

PSN device activation = "this console belongs to this PSN account",
needed to play purchased games.

### RNPS (Restricted Network Profile Service?)

| API | What |
|---|---|
| `_sceSblAuthMgrSmVerifyDecryptRnpsBundle` | Verify + decrypt RNPS bundle |

Probably parental controls / age-rating data.

### GameInfo Container

| API | What |
|---|---|
| `_sceSblAuthMgrSmGicGetData` | Get GameInfo Container data |

GIC = signed metadata bundle that ships with each game (icon, title,
languages, ESRB rating, etc.).

## Function map (first-pass — selected)

### authmgr.c

| Function | Address | Purpose |
|---|---|---|
| `authmgr_helper_ddf50` | `c89ddf50` | (~6 string xrefs) |
| `authmgr_helper_de360` | `c89de360` | (~6 string xrefs — large) |
| `authmgr_helper_de990` | `c89de990` | |
| `authmgr_helper_dea40` | `c89dea40` | |
| `authmgr_helper_deba0` | `c89deba0` | |
| `authmgr_helper_df320` | `c89df320` | |
| **`authmgr_main_dispatch`** | `c89df400` | (~14 xrefs — likely the main op dispatcher) |

### sm_service/service.c

| Function | Address | Purpose |
|---|---|---|
| `sm_service_register` | `c89cbbc0` | Register SM service (small, ~4 xrefs) |

## SELF loading flow (high-level)

```
Userspace dlopen("/system/common/lib/libSomeLib.sprx")
                │
                ↓
Kernel: namei + vop_open
                │
                ↓
ELF loader recognizes SELF magic, calls auth path
                │
                ↓
authmgr.sceSblAuthMgrIsLoadable(path)
                │
                ├── builds query payload
                │
                ↓
authmgr.sceSblAuthMgrAuthHeader(ehdr_bytes, &result)
                │
                ├── sends to SAMU via sbl/driver mailbox:
                │   service_id = AUTH_HEADER, payload = SELF header
                ↓
SAMU (running secure_kernel.elf):
   - Verifies header signature against Sony's RSA public key
   - Checks revocation list (some old SELFs are blacklisted)
   - Returns OK + decrypted block-encryption key
                │
                ↓
authmgr.sceSblAuthMgrLoadSelfBlock(block_n, &out)
                │
                ↓ (per-block, repeated for whole SELF)
SAMU decrypts block using block-key + IV
                │
                ↓
Decrypted bytes get mapped into the loaded process
                │
                ↓
authmgr.sceSblAuthMgrFinalize(handle)
                │
                ↓
ELF loader continues with relocations etc.
```

## Open questions / TODOs

1. **Decompile `authmgr_main_dispatch` (`c89df400`)** — find the
   command opcode table.
2. **Decode `_sceSblAuthMgrSmStart` payload** — what context is needed
   to open a secure-module session?
3. **Map `eekc_mgr.c`** — EEKC is some Sony key encrypting key cluster?
4. **Map `secureclock_sm.c`** — secure (anti-rollback) clock for
   things like time-limited rentals.
5. **Map `checkup.c`** — boot-time integrity checkup?

## Linux equivalent

| Sony AuthMgr | Linux mainline |
|---|---|
| `sceSblAuthMgrAuthHeader` (SELF verify) | IMA (Integrity Measurement Architecture) + EVM |
| `sceSblAuthMgrLoadSelfBlock` (decrypt block) | dm-verity |
| `sceSblAuthMgrPltAuth*` | OAuth2 / TLS client auth |
| `sceSblAuthMgrSmDrive*` (HDD crypto) | dm-crypt / LUKS |
| `sceSblAuthMgrSmGic*` | None — game metadata is Sony-specific |
| `sceSblAuthMgrSmActCode*` | OAuth2 device authorization grant |

For Linux on PS4: zero porting needed.

## Implication for Linux PS4 HDD reading

This room confirms: **the PS4's internal HDD is encrypted with
console-specific keys held by SAMU.** Linux can SEE the HDD as a SATA
device (works via mainline AHCI, already enabled in our patches), but
the PARTITIONS are encrypted. To mount them on Linux we'd need:
1. Linux SBL driver port (weeks-months)
2. Plus the specific `_sceSblAuthMgrSmDriveData` call sequence
3. Plus per-console key derivation (varies per chip)

So our Linux setup uses an **external USB drive with `psxitarch`** for
rootfs and skips Sony's HDD. That's why our boot args include
`root=LABEL=psxitarch`.

## Connections to other rooms

- **sbl/driver** (iter 13): authmgr uses mailbox primitives.
- **sbl/service/keymgr** (iter 14): authmgr derives session keys via
  keymgr.
- **sbl/service/sysveri**: works with authmgr to verify system
  components.
- **sbl/service/np_horizon**: PSN auth uses pltauth_sm flow.
- **sbl/devact**: device activation likely calls Activation APIs from
  this module.
- **regmgr**: stores activation tokens (encrypted) returned by
  sceSblAuthMgrPltAuthResult.
