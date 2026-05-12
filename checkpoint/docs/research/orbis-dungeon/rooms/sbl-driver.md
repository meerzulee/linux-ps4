# Room: sbl/driver — Secure Boot Loader driver layer

**Source paths embedded:**
- `sys/internal/modules/sbl/driver/handler.c` @ string `c8e816ad`
- `sys/internal/modules/sbl/driver/gpuvm.c` @ string `c8e812ef`

**Function address ranges (heuristic):**
- `handler.c`: ~`c89b6550..c89b71b3` + SMU primitives at `c89b80b0/c89b81d0`
- `gpuvm.c`: ~`c89b72a0..c89b8550`

## What this room does

The **kernel-side gateway to the SAMU/SBL** (Secure Access Memory Unit
+ Secure Boot Loader). On AMD APU/SoCs the SAMU is a separate ARM
co-processor with its own firmware, RAM, and crypto hardware. It
runs Sony's signed `secure_kernel.elf` and exposes a mailbox-based
RPC interface to the main FreeBSD kernel.

Two roles:
1. **`handler.c`**: Mailbox protocol — send commands, register reply
   handlers, manage the message-processing kthread (`SceSblMsgTask`).
2. **`gpuvm.c`**: GPU VM context allocation for **secure** operations —
   when SAMU needs to access GPU memory (e.g., to decrypt an HDCP
   frame), it does so through specially-mapped GPU VM contexts.

## Why it matters for Linux on PS4

🔒 **THIS IS THE STRUCTURAL BLOCKER FOR UVD.**

From our UVD bring-up postmortem (`UVD_BRINGUP_MAP.md`):
> The fw is waiting on chip state set during Orbis runtime that Linux
> can't replicate without SBL/SMU access.

This room is **why**. Sony's UVD firmware depends on SMU-set clock
levels, and only the SAMU+SBL can program SMU registers (they're
locked from CPU writes on retail PS4). Linux's amdgpu has no SBL
driver, so it falls back to "no SMU" mode where chip stays at
whatever state Orbis left it before JB.

**Theoretical fix path** (HUGE undertaking):
1. Port handler.c's mailbox protocol to Linux
2. Add a Linux ioctl surface for `sceSblDriverWriteSmuIx`
3. amdgpu calls into our SBL driver to set UVD clocks
4. UVD bring-up succeeds

Effort: probably weeks (handler protocol) + months (cross-checking
all the SBL command codes and reply formats). **Not in scope** for
this dungeon mapping pass — but knowing the structure is valuable
for any future attempt.

## Function map (first-pass)

### handler.c — Mailbox protocol

| Sony function | Address | Purpose |
|---|---|---|
| `sbl_helper_b6550` | `c89b6550` | Major handler (~6 string xrefs) — likely main message dispatch loop or `SceSblMsgTask` |
| `sbl_helper_b6c30` | `c89b6c30` | (PARAM-heavy) |
| `sbl_helper_b6ed0` | `c89b6ed0` | |
| `sbl_helper_b6f80` | `c89b6f80` | |
| `sbl_helper_b7160` | `c89b7160` | (PARAM-heavy — likely register/init) |
| **`sceSblDriverReadSmuIx`** | `c89b80b0` | SMU register READ via SAMU mailbox |
| **`sceSblDriverWriteSmuIx`** | `c89b81d0` | SMU register WRITE via SAMU mailbox |
| `sbl_helper_b82f0` | `c89b82f0` | (PARAM-heavy variant) |
| `sbl_helper_b8410` | `c89b8410` | (PARAM-heavy variant) |
| `sbl_helper_b8530` | `c89b8530` | |
| `sbl_helper_b8550` | `c89b8550` | |

### gpuvm.c — Secure GPU VM contexts

| Sony function | Address | Purpose |
|---|---|---|
| `gpuvm_helper_b72a0` | `c89b72a0` | (likely VM init) |
| `gpuvm_helper_b7380` | `c89b7380` | |
| `gpuvm_helper_b7680` | `c89b7680` | (~6 xrefs — major) |
| `gpuvm_helper_b7af0` | `c89b7af0` | (PARAM-heavy) |
| `gpuvm_helper_b7cd0` | `c89b7cd0` | (~10 xrefs — major) |
| `gpuvm_helper_b7fa0` | `c89b7fa0` | |

## SAMU mailbox protocol (decoded)

From the UVD dig (commit `ca960af`), we already have:

```
sceSblDriverReadSmuIx(smu_index, &out_value):           /* FUN_c89b80b0 */
    samu_write(0x22070, 0xa404)         /* SBL read-SMU service id */
    samu_write(0x22074, smu_index)
    samu_write(0x32, 1)                 /* trigger interrupt to SBL */
    while (samu_read(0x4a) & 1):        /* poll until SBL acks */
        block_on_signal()
    err = samu_read(0x2207c)
    if (!err): *out_value = samu_read(0x22078)
    return err

sceSblDriverWriteSmuIx(smu_index, value):               /* FUN_c89b81d0 */
    samu_write(0x22070, 0xa505)
    samu_write(0x22074, smu_index)
    samu_write(0x22078, value)
    samu_write(0x32, 1)
    while (samu_read(0x4a) & 1): block_on_signal()
    return samu_read(0x2207c)
```

`samu_write/read` (FUN_c885b8a0/c885b8d0 in `gc/samu.c`) reads/writes
at base `(*(DAT_ca726878 + 0x10))` + offset. The SAMU's mailbox is
mmio'd into the GPU's PCIe BAR at offset `0x22070..0x2207c`.

### Service IDs we know

| Cmd code | Service | Purpose |
|---|---|---|
| `0xa404` | SBL_SMU_READ | Read indirect SMU register |
| `0xa505` | SBL_SMU_WRITE | Write indirect SMU register |

The full service-ID table is presumably in handler.c's data section,
or in the dispatcher function in `c89b6550`.

## API surface (extracted from string xrefs)

| Symbol | Likely arguments | Purpose |
|---|---|---|
| `sceSblDriverInitialize` | (cold path) | Boot-time SBL init |
| `sceSblDriverFinalize` | (cold path) | Shutdown SBL |
| `sceSblDriverInitializeResume` | (cold path) | Resume from suspend |
| `sceSblDriverMapPages(addr, npages, &handle)` | (~5 string refs) | Pin pages and grant SAMU access; returns handle |
| `sceSblDriverUnmapPages(handle)` | (~5 string refs) | Release SAMU page access |
| `sceSblDriverRegisterMsgHandler(svc_id, fn, ctx)` | | Register callback for inbound SAMU messages on a service |
| `sceSblDriverReadSmuIx(idx, &out)` | mapped above | SMU read |
| `sceSblDriverWriteSmuIx(idx, val)` | mapped above | SMU write |
| `sceSblDriverSendMappedPagePeakNumToSysLogger` | | Telemetry — peak count of pinned pages |

## kthread

`SceSblMsgTask` (string at `c8e83c11`) — kernel thread that processes
incoming async SAMU messages. Reads from SAMU mailbox, dispatches to
registered handlers (one per service ID).

## Why SBL is locked

The SAMU runs **signed firmware** (Sony's `secure_kernel.elf`) and
acts as a Trust Anchor:
- Holds master keys for HDCP, NPDRM, PFS save data
- Has exclusive access to SMU registers, GPU encryption blocks,
  certain GBASE config bits
- All "trusted" operations go through it
- The CPU can ONLY communicate via the mailbox interface

PSFree-Enhanced jailbreak does NOT compromise the SAMU — it only
gains FreeBSD kernel ring 0. The SAMU is still running Sony's
firmware and won't accept arbitrary commands. So even with full
kernel control, Linux cannot:
- Issue arbitrary SMU writes (only ones SAMU permits)
- Decrypt HDCP-protected video
- Decrypt NPDRM content
- Write to certain GBASE registers (bus token bits)

For UVD specifically: the SAMU likely needs to be told "the host is
about to bring up UVD" so it programs the right SMU clocks. We don't
know the command code or service ID for that message. Reverse-
engineering would require:
1. JTAG-debugging the running PS4 to dump SAMU state
2. Or capturing SAMU mailbox traffic with a logic analyzer during
   Orbis-side UVD use

Both are far out of scope for our project.

## Other SBL submodules (for future iters)

These are visible from the string search but not yet mapped:

| Submodule | Purpose (inferred) |
|---|---|
| `sbl/service/keymgr.c` | Key management (sceSblKeymgr*) |
| `sbl/service/cryptmgr.c` | Crypto operations (sceSblCryptmgr*) |
| `sbl/service/sysveri.c` | System verification at boot/runtime |
| `sbl/service/np_horizon.c` | NPDRM (PSN content protection) |
| `sbl/service/pfs_savedata.c`, `pfs_key.c` | Encrypted save data |
| `sbl/service/encdec_service.c` | Generic encrypt/decrypt |
| `sbl/service/ccp/{ccp_sched,ccp_req,sched_qfifo,sched_qprio,sched_qlar,msg}.c` | AMD CCP (Crypto CoProcessor) — actual hardware crypto offload |
| `sbl/service/crepo.c` | "Certificate Repository"? |
| `sbl/service/cloudsd.c` | Cloud save data |
| `sbl/service/bar.c` | BAR access? |
| `sbl/service/rootparam.c` | Root params from PUP |
| `sbl/service/utils.c` | Utility helpers |
| `sbl/sm_service/{service,io,req}.c` | Secure-module service interface |
| `sbl/srtc/srtc_drv.c` | Secure RTC |
| `sbl/pup_update/pup_update.c` | PS4 firmware update path |
| `sbl/eipk_addsign/eipk_addsign_drv.c` | Entry-package signing |
| `sbl/devact/devact.c` | Device activation (PSN) |
| `sbl/pltauth/pltauth2.c` | Platform authentication |
| `sbl/authmgr/{self_file, pltauth_sm, authmgr_secure_module, secureclock_sm, authmgr, eekc_mgr, checkup}.c` | Auth Manager (validates ELFs, .pkg files, etc.) |
| `sbl/vtrm/two_bank/vtrm_utils.c` | Volatile Trusted RAM (anti-rollback) |
| `sbl/rng/rng_drv.c` | Hardware random number generator |
| `sbl/idata/idata_drv.c` | Sony's per-console identity area |
| `sbl/usb_dongle/usb_dongle.c` | USB jig (factory mode) |
| `sbl/qafutkn/qafutkn_drv.c` | QA / factory token |
| `sbl/npdrm/{npdrm_drv,np_drm}.c` | Network Platform DRM |
| `sbl/zlib/zlib_drv.c` | zlib in-kernel (for signed payload decompress) |
| `sbl/lvp_config/lvp_config.c` | Liverpool config blob |

## Open questions / TODOs

1. **Decompile `c89b6550`** (handler.c's biggest function) — find the
   message-dispatch loop and full service ID table.
2. **Decompile `c89b80b0/c89b81d0`** in detail — already have the
   mailbox protocol but might find more service IDs in the wrapper
   format.
3. **Decompile `gpuvm.c`** — the secure GPU VM contexts. Critical for
   understanding HDCP-protected frame paths.
4. **Find where `sceSblDriverMapPages` writes the page list** to SAMU —
   that's the IOMMU bridge protocol.
5. **Check if there's a "SAMU sleeping" state** the host can detect.
   Might inform UVD: maybe SAMU is sleeping when Linux tries to talk
   to it, which would explain why our SMU programming wouldn't work
   even if we ported the protocol.

## Linux equivalent

| Sony SBL | Linux mainline |
|---|---|
| SAMU mailbox protocol | None upstream — would need a custom Linux SBL driver |
| `sceSblDriverWriteSmuIx` | None — SMU writes are normally handled by amdgpu's PMU/SMU code, but on PS4 those are locked |
| `sceSblKeymgr*` | TPM 2.0 abstraction (similar role, different protocol) |
| `sceSblCryptmgr*` | crypto API + ccp driver (`drivers/crypto/ccp/`) — same hardware! |
| `sceSblPfs*` | dm-crypt / fscrypt |
| `sceSblNpDrm*` | None — no equivalent for content DRM |
| `sceSblAuthMgr*` | IMA / EVM (signed file integrity) |
| `sbl/zlib` | Linux kernel zlib |
| `sbl/srtc` | RTC class drivers |

For Linux on PS4: **no port work for everyday use**. We don't need
PSN content, save data encryption, or content DRM. The one thing we'd
WANT is `sceSblDriverWriteSmuIx` so amdgpu can program GPU clocks
properly — that's the structural UVD blocker.

## Connections to other rooms

- **gc** room: `gbase_update_vddnb` calls `sceSblDriverWriteSmuIx` to
  set NB voltage. Same path used for any SMU programming.
- **uvd / vce** room: would need SBL access to fully bring up — see
  postmortem.
- **regmgr** room: stores Sony account info, encrypted via SBL keymgr.
- **bt / wlan** rooms: WiFi passwords stored encrypted via SBL.
- **ipmimgr** room: SBL services expose IPMI endpoints to userspace.
