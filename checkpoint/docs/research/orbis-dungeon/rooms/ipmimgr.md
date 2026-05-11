# Room: ipmimgr — Inter-Process Messaging Manager (IPC backbone)

**Source paths embedded:** 14 files under `sys/internal/modules/ipmimgr/`:

| File | String addr |
|---|---|
| `ipmimgr.c` | `c8ec2993` |
| `ipmimgr_create.c` | `c8ec0eec` |
| `ipmimgr_destroy.c` | `c8ec1988` |
| `ipmimgr_connect.c` | `c8ebf9e8` |
| `ipmimgr_disconnect.c` | `c8ec14f3` |
| `ipmimgr_channel.c` | `c8ec3065` |
| `ipmimgr_msg_queue.c` | `c8ec026c` |
| `ipmimgr_event_queue.c` | `c8ec04fc` |
| `ipmimgr_eventflag.c` | `c8ec129d` |
| `ipmimgr_async.c` | `c8ec1b46` |
| `ipmimgr_sync.c` | `c8ec0782` |
| `ipmimgr_kid.c` | `c8ec00a1` |
| `ipmimgr_common.c` | `c8ec1199` |
| `ipmimgr_coredump.c` | `c8ebf00b` |
| `ipmimgr_debugger.c` | `c8ec350a` |

**Function address range:** ~`c8a90000..c8aa9fff`

## What this room does

**IPMI** = Inter-Process Messaging Interface. PS4's main IPC backbone
for "system service" RPC calls. This is the equivalent of:
- Android's Binder
- macOS's Mach IPC
- D-Bus on Linux desktops

PS4 system services (registry, power, network, controllers, store
launcher, etc.) all run as separate processes and expose IPMI server
endpoints. Game processes and other clients connect to them by name.

**Resources managed:**
- Servers (created via `sceIpmiMgrCreateServer`)
- Connections (client ↔ server pairings)
- Channels (multiplexed message paths within a connection)
- Message queues, event queues, event flags, async ops

## Why it matters for Linux on PS4

🔍 **Mostly NOT directly relevant** — Linux on PS4 doesn't run any
PS4 system services. We use Linux's own IPC (D-Bus, Wayland, etc.).

Two indirect uses:
1. **Reverse-engineering Sony userspace.** If we ever want to interact
   with running Sony components (debug or compatibility mode), we'd
   need to send IPMI messages. The sycall-level surface is mapped
   here.
2. **PS4 firmware update / system file manipulation.** SCE's
   `pup_update` flow uses IPMI to communicate between the kernel and
   the secure firmware updater process.

For our Linux port, mapping ipmimgr is **dungeon-completion** rather
than load-bearing. Useful for understanding the broader Sony
userspace architecture.

## Function map (first-pass)

### Top-level dispatch (probably `ipmimgr.c` syscall table)

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `ipmimgr_helper_aa1fc0` | `c8aa1fc0` | **MASSIVE function** (~30 string xrefs to ipmimgr.c) — likely the syscall dispatcher |
| `ipmimgr_helper_aa4bc0` | `c8aa4bc0` | Major handler (~14 xrefs) |
| `ipmimgr_helper_aa5d60` | `c8aa5d60` | (~4 xrefs) |
| `ipmimgr_helper_aa6500` | `c8aa6500` | (~4 xrefs) |

### `ipmimgr_create.c`

| Sony function | Address | Purpose |
|---|---|---|
| **`syscallCreateServer`** | `c8a97010` | Create a named IPMI server endpoint (the syscall) |
| `syscallCreateClient_helper` | `c8a979d0` | Helper for client side |

### `ipmimgr_channel.c`

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `ch_helper_77e0` | `c8aa77e0` | Channel utility |
| **`ch_alloc_vthread`** | `c8aa79e0` | Allocate vthread (msg ring container) |
| `ch_helper_7ad0` | `c8aa7ad0` | (called after vthread alloc — populate fields) |
| `ch_helper_7b90` | `c8aa7b90` | Free vthread on error path |
| `ch_helper_7c60` | `c8aa7c60` | |
| `ch_helper_7e90` | `c8aa7e90` | (5 xrefs — major) |
| `ch_helper_8490` | `c8aa8490` | |
| `ch_helper_88e0` | `c8aa88e0` | |
| `ch_helper_8a80` | `c8aa8a80` | |
| `ch_helper_8ca0` | `c8aa8ca0` | |
| `ch_helper_8db0` | `c8aa8db0` | |
| `ch_helper_8ee0` | `c8aa8ee0` | |
| `ch_helper_9150` | `c8aa9150` | |
| `ch_helper_93a0` | `c8aa93a0` | |
| `ch_helper_94a0` | `c8aa94a0` | |
| `ch_helper_9680` | `c8aa9680` | |
| **`ch_register_vthread`** | `c8aa9940` | Register vthread with kid |

### Other modules

| Symbol | Address | Likely role |
|---|---|---|
| `ipmi_alloc_kid` | `c8a90db0` | Allocate kernel ID (= file descriptor equivalent) |
| `ipmi_release_kid` | `c8a91560` | Release kernel ID |
| `ipmi_event_alloc` | `c8a932c0` | Allocate event-queue entry |
| `ipmi_event_post` | `c8a93d00` | Post event to subscribers |
| `ipmi_kid_close` | `c8a9e4a0` | Final-close kid |
| `ipmi_post_debug_event` | `c8a88b90` | Debug-event log (debugger.c) |

## Server lifecycle (from `syscallCreateServer` decompile)

```
Userspace: sceIpmiCreateServer(name="MyService", options={msg_size, event_size, ...}, &serverHandle)
                        │
                        ↓ syscall trap
Kernel: syscallCreateServer(proc, args, retval)
   1. Validate caller is debug-allowed (FUN_c874e780 returns 1)
   2. copyinstr(args.name, &local_name, 0x19)
   3. Post debug event 0x1700 (CREATE_SERVER_BEGIN)
   4. copyin(args.options, &opts, 0x38)  — 56 bytes of options
   5. Validate opts: 
        flag_low ≤ 0x38
        max_msg_size  ≤ 0x100001  (1 MB)
        max_event_size ≤ 0x2001   (8 KB)
        bool_flags 0..1 each
   6. Acquire global IPMI registry lock at DAT_c9e99f68
   7. Walk DAT_c9e99f68+0x20 (server list), reject if name collides
   8. Append null-terminator to name (CONNECT_REQUEST_FLAG_LINKED check)
   9. Allocate vthread (0x2000 bytes) via ch_alloc_vthread
  10. Allocate kid (0x8001 type) for the server
  11. Init vthread state via ch_helper_7ad0
  12. Lock the IPMI registry, lock the server's mutex
  13. Populate server struct (size ~0xa0):
        +0x28 mutex
        +0x48 syscall id
        +0x50/+0x58 prev/next in server list
        +0x68 head of connections
        +0x70 connection count
        +0x78 vthread/kid
        +0x7c flags (max=0x100002)
        +0x7e bits (single-client / cross-pid)
        +0x80 max_msg_size
        +0x88 max_event_size
        +0x90/+0x98 userdata
  14. Splice into registry list at +0x28
  15. Walk pending CONNECT_REQUESTs at registry+0x38:
        For each request matching name:
          - Set request kid = server's kid
          - If too many connections (>0x40), set kFlag CONNECT_REQUEST_FLAG_FULL
          - If options mismatch (msg_size, pid_check), set FLAG_REJECTED
          - Otherwise: link a CONNECTION_CB to the server's connection list
          - Track client ucred + pid for matched events
  16. Return server kid via *retval
  17. Post debug event 0x1701 (CREATE_SERVER_END) with kid
```

Connection-pending requests (from clients that called connect BEFORE the
server was created) get matched and woken up here.

## Key data structures

### Global IPMI registry (`DAT_ffffffffc9e99f68`)

| Offset | Field |
|---|---|
| `+0x00..+0x18` | mutex |
| `+0x20` | head of server list |
| `+0x28` | tail of server list (or doubly-linked head) |
| `+0x30` | server count |
| `+0x38` | head of pending CONNECT_REQUESTs |

### Server struct (~0xa0 bytes)

| Offset | Field |
|---|---|
| `+0x28..+0x47` | per-server mutex |
| `+0x48` | syscall id |
| `+0x50/+0x58` | next/prev in server list |
| `+0x68` | head of CONNECTION_CB list |
| `+0x70` | active connection count (max 64) |
| `+0x78` | vthread/kid pointer |
| `+0x7c` | flags (bit 0x20000, 0x40000, 0x100000) |
| `+0x7e` | bool bits (single-client, cross-pid, other-pid) |
| `+0x80` | max_msg_size (1 MB max) |
| `+0x88` | max_event_size (8 KB max) |
| `+0x90/+0x98` | server userdata |

### CONNECT_REQUEST struct (~0x70 bytes)

| Offset | Field |
|---|---|
| `+0x00..+0x10` | linked list pointers + state |
| `+0x14` | flags (CONNECT_REQUEST_FLAG_LINKED bit 0, REJECTED bit 0x100, FULL bit 0x400, ...) |
| `+0x18` | proc id of caller |
| `+0x1c` | request id |
| `+0x24` | target_pid (filled by server during match) |
| `+0x28..+0x47` | server name (compared with strncmp 0x20) |
| `+0x48` | userdata |
| `+0x50` | max_msg_size requested |
| `+0x68` | wait queue / condvar |

### CONNECTION_CB struct (~0x48 bytes)

| Offset | Field |
|---|---|
| `+0x20` | flags (CONNECTION_CB_FLAG_LINKED_SERVER_CB bit 4) |
| `+0x28/+0x30` | next/prev in server's connection list |
| `+0x38` | server kid |
| `+0x3c` | pid |
| `+0x40` | max_msg_size |

## Debug event log

Debug events are posted via `ipmi_post_debug_event` (FUN_c8a88b90)
with:
- `0x1700` = CREATE_SERVER_BEGIN
- `0x1701` = CREATE_SERVER_END

These are read by an IPMI debugger process (probably part of Sony's
SDK tools, not the production console) for tracing.

## Error code family

`SCE_KERNEL_ERROR_IPMI_*` errors use base `0x80020320` + offset.
Examples seen in `syscallCreateServer`:
- `local_2d8 - 0x7ffe0000` is the canonical error formula
- Sub-codes 0..0xE encode WHICH validation failed
- Mapped to errno-style values inside (1=EPERM, 2=ENOENT, etc.)

## Open questions / TODOs

1. **Decompile `c8aa1fc0`** — the massive (~30 string xrefs) probable
   syscall dispatcher in `ipmimgr.c`. Lists all syscall numbers.
2. **Decompile `syscallCreateClient`** in connect.c — should mirror
   create-server with the client-side handshake.
3. Find the **kid** abstraction: it's an int handle similar to
   FreeBSD's file descriptor. Defined in `ipmimgr_kid.c`. Useful
   to know if it overlaps with normal fds (it might).
4. **Map the message types** sent over IPMI: probably a header
   struct with sender pid + msg type + payload size + payload.
5. **Cross-reference clients**: which OTHER kernel modules call
   into IPMI? Probably `regmgr`, `pup_update`, `bt`, `wlan`.

## Linux equivalent

| Sony IPMI | Linux mainline |
|---|---|
| Server endpoint | D-Bus service, or Unix socket listener |
| Client connection | D-Bus method call, or Unix socket connect |
| Message queue | Unix socket DGRAM with SO_RCVBUF |
| Event queue | epoll / signalfd |
| Event flag | eventfd |
| Async op | io_uring |
| Kid (kernel id) | File descriptor |

For Linux on PS4: no port needed. Linux apps use D-Bus, Wayland, etc.

## Connections to other rooms

- Many other Sony modules use IPMI to talk to userspace services.
  When mapping `bt`, `wlan`, `regmgr`, `pup_update`, look for IPMI
  client/server endpoints.
- `ipmimgr_coredump.c` — captures IPMI state in panic dumps. Useful
  for debugger traces.
- `ipmimgr_debugger.c` — debugger interface. Posts events `0x17xx`.
