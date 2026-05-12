# Room: sbl/service — SBL service layer (20 files)

**Source paths embedded:** All under `sys/internal/modules/sbl/service/`:

| File | String addr | Likely role |
|---|---|---|
| `service.c` | `c8e8444e` | Service init / registry |
| `keymgr.c` | `c8e84e99` | Key management (sceSblKeymgr*) |
| `cryptmgr.c` | `c8e8599d` | Crypto operations (sceSblCryptmgr*) |
| `sysveri.c` | `c8e84803` | System verification |
| `np_horizon.c` | `c8e84500` | NPDRM (PSN content protection) |
| `pfs_savedata.c` | `c8e840b2` | Encrypted save data |
| `pfs_key.c` | `c8e847bb` | PFS encryption keys |
| `encdec_service.c` | `c8e846b8` | Generic encrypt/decrypt |
| `crepo.c` | `c8e81b52` | Certificate repository |
| `cloudsd.c` | `c8e81e78` | Cloud save data |
| `bar.c` | `c8e85040` | BAR (PCIe BAR or Backup-and-Restore) |
| `rootparam.c` | `c8e85145` | Root params from PUP |
| `patch.c` | `c8e83e8d` | Runtime patches |
| `utils.c` | `c8e84e21` | Utility helpers |
| `ccp/msg.c` | `c8e83c1f` | CCP message format |
| `ccp/ccp_req.c` | `c8e843f4` | CCP request submission |
| `ccp/ccp_sched.c` | `c8e842b9` | CCP scheduler |
| `ccp/sched_qfifo.c` | `c8e83ef0` | CCP FIFO queue scheduler |
| `ccp/sched_qprio.c` | `c8e84722` | CCP priority queue scheduler |
| `ccp/sched_qlar.c` | `c8e850ac` | CCP "QLAR" scheduler (queue-LAR?) |

**Function address ranges:**
- `service.c`: ~`c89c0a60..c89c0bd5` (small)
- `keymgr.c`: ~`c89c6ad0..c89c8854` (large, ~30 functions)
- `cryptmgr.c`: ~`c89caec0..c89cb252` (small)
- Others span the `c89c*..c89e*` range

## What this room does

The SBL service layer sits between the kernel-side `sbl/driver` (the
mailbox transport) and the userspace IPMI clients. Each `sceSbl*`
syscall ultimately routes through this layer to issue commands to
SAMU.

```
userspace                                kernel-side                     SAMU
─────────                                ───────────                     ────
sceSblKeymgr...   →  IPMI server  →  sbl/service/keymgr.c  →  sbl/driver/handler.c
                                            │
                                            └── sends mailbox cmd to SAMU
                                                                            │
                                                              ←  reply  ←  Sony's secure_kernel.elf
                                            │
sceSblKeymgr...  ←  result  ←  ←  ←  ←  ←  ┘
```

Three logical sub-layers:

1. **Service registry** (`service.c`) — boot-time registration of
   each sub-service with the IPMI manager.
2. **Per-service kernel handlers** (`keymgr`, `cryptmgr`, `pfs_*`,
   `npdrm`, `sysveri`, `crepo`, `cloudsd`, `bar`, `rootparam`,
   `patch`, etc.) — translate userspace requests into SAMU mailbox
   commands.
3. **CCP support code** (`ccp/*`) — the Crypto CoProcessor (an AMD
   PSP block) is used for hardware crypto offload. Has its own
   request/scheduler/queue infrastructure.

## Why it matters for Linux on PS4

🟡 **Mostly NOT relevant.** Linux on PS4 doesn't need:
- DRM-protected content (NPDRM, np_horizon)
- Encrypted save data (pfs_savedata, pfs_key, cloudsd)
- ELF/PKG signature checks (sysveri, authmgr from prior room)
- Cert management (crepo)
- BAR/rootparam (boot-time from PUP — Linux has its own boot)

Two things that COULD be useful:
1. **`cryptmgr` + `ccp/*`**: The AMD CCP is the same hardware as
   `drivers/crypto/ccp/` in mainline Linux. Mainline already supports
   it — Linux's CCP driver works on Liverpool. So we get hardware
   AES/SHA acceleration for free if we want it.
2. **`keymgr`**: Has the per-console "user keys" used for various
   things. NOT useful for Linux directly.

## Function map (very brief — selected functions)

### service.c — service-registry (small)

| Function | Address | Purpose |
|---|---|---|
| `sbl_svc_helper_a60` | `c89c0a60` | Service init helper |
| `sbl_svc_register` | `c89c0b90` | Register a service with the IPMI manager |

### keymgr.c — Key management (largest)

| Function | Address | Purpose (inferred) |
|---|---|---|
| `keymgr_helper_6ad0` | `c89c6ad0` | (~5 string xrefs) |
| `keymgr_helper_6c00` | `c89c6c00` | |
| `keymgr_helper_6c70` | `c89c6c70` | |
| `keymgr_helper_6db0` | `c89c6db0` | |
| `keymgr_helper_6ef0` | `c89c6ef0` | |
| **`keymgr_main_dispatch`** | `c89c7030` | Likely the syscall dispatcher (multi-xref) |
| `keymgr_helper_71d0` | `c89c71d0` | |
| `keymgr_helper_7370` | `c89c7370` | |
| `keymgr_helper_74a0` | `c89c74a0` | |
| `keymgr_helper_7590` | `c89c7590` | |
| `keymgr_helper_7680` | `c89c7680` | |
| `keymgr_helper_7a90` | `c89c7a90` | |
| `keymgr_helper_7b20` | `c89c7b20` | |
| `keymgr_helper_7ca0` | `c89c7ca0` | |
| `keymgr_helper_7d40` | `c89c7d40` | |
| `keymgr_helper_7df0` | `c89c7df0` | |
| `keymgr_helper_8010` | `c89c8010` | |
| `keymgr_helper_81b0` | `c89c81b0` | |
| `keymgr_helper_84c0` | `c89c84c0` | |
| `keymgr_helper_8590` | `c89c8590` | |
| `keymgr_helper_8750` | `c89c8750` | |

### cryptmgr.c — Crypto operations (small)

| Function | Address | Purpose |
|---|---|---|
| `cryptmgr_helper_aec0` | `c89caec0` | |
| `cryptmgr_helper_af50` | `c89caf50` | (PARAM-heavy — main op) |
| `cryptmgr_helper_b010` | `c89cb010` | |
| `cryptmgr_helper_b120` | `c89cb120` | |
| `cryptmgr_helper_b1d0` | `c89cb1d0` | |

### Other services (function ranges TBD — high-level only this iter)

Each of: `np_horizon`, `pfs_savedata`, `pfs_key`, `encdec_service`,
`crepo`, `cloudsd`, `bar`, `rootparam`, `patch`, `utils`, `sysveri`,
`ccp/*` follows the same pattern: the kernel-side handler is a thin
wrapper around `sceSblDriverRegisterMsgHandler` + per-command
dispatch. Each handler:
1. Receives an IPMI request from userspace
2. Validates parameters
3. Maps any user buffers via `sceSblDriverMapPages`
4. Issues a mailbox command via SAMU service ID + args
5. Waits for reply
6. Unmaps pages
7. Returns result via IPMI reply

## Service ID space (partial)

From string evidence:

| Service prefix | Where |
|---|---|
| `sceSblKeymgr*` (Sm = "Secure Module") | keymgr.c |
| `sceSblKeymgrSmCallfuncWithID(Init/Result)` | seen in sysveri init path |
| `sceSblKeymgrLockKey` | seen in error string at c8eb31a9 |
| `sceSblCryptmgr*` | cryptmgr.c |
| `sceSblPfs*` | pfs_savedata, pfs_key |
| `sceSblNpDrm*` | np_horizon (PSN content) |
| `sceSblSysVeri*` | sysveri.c |
| `sceSblAuthMgr*` | authmgr (covered in next iter) |

## CCP (Crypto CoProcessor) layer

`ccp/` subdirectory has its own queue/scheduler abstraction:

```
ccp_req (request submission)
   └── ccp_sched (scheduler dispatch)
        ├── sched_qfifo (FIFO queue — basic)
        ├── sched_qprio (priority queue — for time-sensitive ops)
        └── sched_qlar (specialized queue — possibly "Long-Async-Request")
   └── msg (request/response message format)
```

This is essentially Sony's wrapper around the AMD CCP hardware blocks.
Mainline Linux has the same hardware support in
`drivers/crypto/ccp/ccp-*.c`.

## Open questions / TODOs

1. **Map the `cryptmgr_helper_af50`** function — likely the dispatcher
   for AES / SHA / RSA operations exposed to userspace.
2. **Decode keymgr "Sm Callfunc" pattern** — strings reference
   `sceSblKeymgrSmCallfuncWithID(Init)` and `(Result)` — suggests
   a generic "call secure module function by ID" + "get result" RPC.
3. **Trace ccp/sched_qlar** — what's the LAR scheduling discipline?
   Linux's CCP doesn't have an equivalent.
4. **Map `pfs_key.c`** — would tell us what derivation function Sony
   uses for save-data keys (probably PBKDF2 or HKDF over per-console
   master).
5. **Find the IPMI server-name strings** — each service registers as
   "SceSblKeymgrSrv" or similar. Useful to confirm the service-name
   ↔ source-file mapping.

## Linux equivalent

| Sony SBL service | Linux mainline |
|---|---|
| `keymgr` | TPM 2.0 keys / kernel keyring |
| `cryptmgr` (AES/SHA dispatch) | crypto API (`crypto/`) |
| `ccp/*` | `drivers/crypto/ccp/ccp-*.c` (same HW, Linux supports it) |
| `pfs_savedata`, `pfs_key` | dm-crypt / fscrypt |
| `np_horizon` | None — no equivalent |
| `sysveri` | IMA / EVM |
| `crepo` | Kernel keyring trusted certs |
| `cloudsd` | None — Linux doesn't do cloud save sync |
| `bar`, `rootparam` | DT / EFI vars / kernel cmdline |
| `patch` | Live patching (kpatch) |

For Linux on PS4: **only `cryptmgr` + `ccp/*` matter**, and mainline
Linux already drives the same CCP hardware via the upstream CCP
driver. So no porting needed.

## Connections to other rooms

- **sbl/driver** (prev iter): all services use its mailbox primitives.
- **sbl/authmgr** (next iter): auth manager uses keymgr/cryptmgr for
  signature verification.
- **regmgr**: stores encrypted user account data via pfs_savedata
  primitives.
- **bt** / **wlan**: WiFi passwords likely encrypted via
  pfs/keymgr primitives.
- **ipmimgr**: each SBL service is an IPMI server endpoint.
- **uvd / vce**: HDCP path goes through CCP for HDMI encryption.
