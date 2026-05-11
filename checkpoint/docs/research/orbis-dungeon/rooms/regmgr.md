# Room: regmgr — Registry Manager

**Source paths embedded:**
- `sys/internal/modules/regmgr/regmgr.c` @ string `c8bd0eb3`
- `sys/internal/modules/regmgr/regmgr_event.c` @ string `c8bd25fc`
- `sys/internal/modules/regmgr/regmgr_driver.c` @ string `c8bd2d88`

**Function address ranges (heuristic from xrefs):**
- `regmgr.c`: ~`c8884000..c888ce00`
- `regmgr_event.c`: ~`c8899e00..c889a100`
- `regmgr_driver.c`: ~`c889d000..c889ef90`

## What this room does

Sony's REGMGR is the **persistent key-value store** for system
preferences. PS4 uses it to remember settings like display resolution,
audio config, parental controls, network creds (encrypted), user
account associations, etc. The Vita has the same subsystem (also called
`SceRegMgr`).

Storage layout:
- 3 file backings (probably `/system/registry.db`, `.bak`, `.idx`)
- ~64 KB of entry table (0xffe = 4094 entries × 0x10 bytes per slot)
- Each entry has ID (uint32) + size (uint16) + type (uint16) + content

Entry types observed:
- `0` = u8/u16/u32/u64 scalar value (size determines width)
- `1` = variable-length binary blob
- `2` = ?

Error code prefix: `0x800d02XX` (Sony's `SCE_KERNEL_ERROR_REGMGR_*`).

## Why it matters for Linux on PS4

**It doesn't, directly.** PS4's REGMGR is Sony's userspace storage
infrastructure for *Orbis* preferences. Linux on PS4 doesn't share or
need access to it.

But three reasons it's worth understanding:

1. **It might hold per-machine config we'd want for Linux.** If
   REGMGR has the HDMI EDID override, audio mixer presets, or specific
   PCI device IDs that Sony probed at boot and cached, those would be
   useful inputs to our Linux kernel patches.

2. **It uses a custom file I/O syscall surface** (the `0x3008001`,
   `0x3008003` codes in `FUN_c8883d70` calls). That gives us a peek at
   Sony's filesystem syscall numbering — useful when reading other
   modules.

3. **It mutexes via `FUN_c8714d30(name, type, count)`** which is the
   FreeBSD-derived `mtx_init()` — handy to know the calling convention
   when reading other modules.

## Function map (first-pass)

| Sony function | Address | Purpose | Notes |
|---|---|---|---|
| `regmgr_lookup_entry` | `c8884620` | Find entry by ID + validate type/size | First-pass guess from arg pattern + return codes |
| `regmgr_set_entry` | `c8886af0` | Update entry (calls FUN_c8886e30(0x40, ...) then FUN_c8886e30(0, ...)) | Two-stage: stage in scratch, then commit |
| `regmgr_validate_init` | `c888ca40` | Probably "is registry initialized" check | Called from `set_entry` before allowing writes |
| `regmgr_event_emit` | `c8899e70` | Emit a registry event (subscriber notify) | Called on errors with codes 0x800d020d etc. |
| `regmgr_event_emit_2` | `c8899fc0` | Variant of `event_emit` | Same source file, similar structure |
| `regmgr_driver_init` | `c889d0e0` | **Module init** — alloc state, open backing files, validate entries | The main constructor |
| `regmgr_driver_walk_entry` | `c889e110` | Iterate one entry from the on-disk table | TBD — first xref |
| `regmgr_driver_check_entry` | `c889e3e0` | Validate one entry checksum | |
| `regmgr_driver_open_handle` | `c889e690` | ? | |
| `regmgr_driver_compute_chk` | `c889e940` | Checksum computation | Called twice for each entry during init |
| `regmgr_driver_finalize` | `c889ec50` | Stage commit | |
| `regmgr_internal_io` | `c8886e30` | Generic stage/commit primitive | Used by `set_entry`; arg 0x40 = "stage", 0 = "commit" |

(There are likely 30-50 more functions in the address ranges above
that this first pass hasn't disambiguated. Mark for deeper dig if
needed for a Linux feature.)

## Key data structures

`DAT_ffffffffca7e5df0` — REGMGR module state, 0x10148 bytes:
- `+0x000` to `+0x0FF` — 3 file path strings (3 × 0x50)
- `+0x100` — mutex `"SceRegMgrDrv"`
- `+0x108` — mutex owner ptr
- `+0x110` — mutex hold count
- `+0x114` — flags
- `+0x130` — header buffer (read first 0x10004 bytes from disk into here)
- `+0x154 ... +0x10133` — entry table (4094 × 0x10 bytes)
- `+0x10134` — last 0x14 bytes: ?

`DAT_ffffffffca7da584` — IN-MEMORY entry table (different from on-disk):
- Stride 0x12 bytes per entry (or 0x24 / 9)
- `+0x00` (4 bytes): entry ID
- `+0x04` (1 byte): array count (for ID-aliasing)
- `+0x05` (1 byte): bit-stride for array
- `+0x10` (2 bytes): type
- `+0x12` (2 bytes): size

`DAT_ffffffffca7da574` — total in-memory entry count (uint32).

## Syscall / IPC surface

The REGMGR is accessed via the Sony syscall:
- Open the regmgr device node: probably `/dev/reg` or via IPMI
- ioctl/read/write through that fd

The file I/O it uses is via internal syscall codes:
- `0x3008001` — open file mode 1 (probably "open existing or fail")
- `0x3008003` — open file mode 3 (probably "open or create")

The `0x800d020X` error code family suggests this maps to userspace
`sceRegMgr*` functions (libSceRegMgr.sprx).

## State machine

```
[uninitialized]
    │
    ↓ regmgr_driver_init()
[file_open_fail]                         [files_open]
                                            │
                                            ↓ read 0x10004 bytes
                                         [validate_header]
                                            │ checksum bad
                                            ↓
                                         [migrate / re-init]
                                            │ all entries valid
                                            ↓
                                         [running]   ← ready for IOCTL
                                            │
                                            ↓ regmgr_set_entry(id, val)
                                         [stage]
                                            ↓ commit
                                         [running]
                                            ↓ regmgr_event_emit(...)
                                         (subscribers notified)
```

## Open questions / TODOs

1. Find the **device node** — probably created via `cdev_register` in
   `regmgr_driver.c`. Need to find caller of `make_dev` / FreeBSD
   equivalent in this address range.
2. Decode the file format on disk. Header is 0x10004 bytes. First few
   bytes likely a magic + version. Sony's PUP update process probably
   handles version migration here.
3. Find the IOCTL handler (`d_ioctl_t` field of the `cdev_sw_t`).
4. Cross-reference: which other modules read REGMGR entries at boot?
   If display init reads e.g. EDID hash from REGMGR, that's a clue for
   our Linux HDMI work.
5. Map the second source file (`regmgr_event.c`) — looks like a
   pub/sub mechanism for entry-change notifications. Might be useful
   for Linux's PS4-side event listening.

## Linux equivalent

Linux has nothing exactly like this. Closest analogues:
- **systemd's `tmpfiles.d` / `sysctl.d`** — config files, but read-once.
- **eCryptfs / encrypted file storage** for the secure-key-managed
  parts.
- **gconf / dconf** — key-value store with change notifications.
- **`/sys/firmware/efi/efivars/`** — persistent k/v storage in EFI vars.

For our Linux-on-PS4 port: we don't need to replicate REGMGR. If we
need to read PS4-specific config (like EDID), better to pull it from
`/system/registry.db` directly via the `mnt/system` partition mount
(after we have HDD access — currently AHCI works).
