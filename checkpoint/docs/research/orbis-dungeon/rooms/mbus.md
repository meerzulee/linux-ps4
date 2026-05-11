# Room: mbus — Message Bus (AV hotplug event router)

**Source paths embedded:**
- `sys/internal/modules/mbus/mbus_event.c` @ string `c8e77f54`
- `sys/internal/modules/mbus/mbus_kmod.c` @ string `c8e78493`

**Function address ranges (heuristic from xrefs):**
- `mbus_event.c`: ~`c896e480..c8970390`
- `mbus_kmod.c`: ~`c8970960..c89719d8`

## What this room does

Despite the name "message bus", mbus is **specifically the AV
hotplug event router**. It tracks HDMI connect/disconnect, AV device
appearance, and broadcasts those state changes to subscribers across
the kernel (audio mixer, display compositor, etc).

Two kmem cache pools are created at init:
- `mbus` cache: ~0x180 bytes per object — generic event subscribers
- `mbus_av` cache: ~0x180 bytes per object — AV-specific events

Two protected lists hold active subscribers, gated by:
- mutex `mbus_lock`
- condvar `mbus_cv` (for blocking subscribers)

## Why it matters for Linux on PS4

**Very relevant** — `event_id == 9` is the HDMI connect/disconnect
event. Sony's HDMI bridge (`ps4_bridge_cq` in mainline crashniels
fork) probably feeds events INTO mbus, and the audio subsystem reads
OUT of mbus to switch sinks when HDMI changes.

For Linux on PS4, the equivalent flow is:
- `amdgpu` detects HDMI connect via the bridge chip (we have this
  partially working via `ps4_bridge.c`)
- Sends a `KOBJ_CHANGE` uevent for the DRM connector
- Userspace (logind, audio daemon) reacts via udev

Our Linux port doesn't need to replicate Sony's mbus, but
understanding mbus's **state machine** tells us the HDMI sequence Sony
expects, which informs the HDMI bridge driver we still need to debug.

Specifically:
- mbus tracks "deviceId" that increments on each CONNECT (1, 2, ...
  up to 0x10000). Sony's downstream subscribers use this to detect
  "this is a NEW connection, not just a re-connect".
- The 3 ms condvar timeout on backpressure (line 0x381) tells us
  Sony's HDMI debouncer has 3 ms minimum gap.

## Function map (first-pass)

### mbus_kmod.c — Module lifecycle

| Sony function | Address | Purpose |
|---|---|---|
| `mbus_module_op` | `c8970960` | Module init/deinit dispatch (op 0=init, 1=deinit) |
| `mbus_suspend_phase1` | `c8970da0` | EVENTHANDLER for system suspend |
| `mbus_resume_phase1` | `c8970dd0` | EVENTHANDLER for system resume |
| `mbus_subscribe` | `c8970eb0` | Register an event subscriber (3 xref slots — adds to list) |
| `mbus_unsubscribe` | `c8971260` | Remove subscriber (called multiple times — different paths) |
| `mbus_post_event_sync` | `c89714e0` | Synchronous post (waits for delivery) |
| `mbus_post_event_async` | `c8971570` | Asynchronous post |
| `mbus_query_state` | `c8971730` | Read current state of an event_id |
| `mbus_get_av` | `c89718e0` | Get AV-specific subscriber info |
| `mbus_av_lookup` | `c8971970` | Find AV subscriber by criteria |

### mbus_event.c — Event posting + HDMI state machine

| Sony function | Address | Purpose |
|---|---|---|
| `mbus_event_post_hdmi` | `c896e480` | **EVENT_ID 9 specialized** — HDMI connect/disconnect with device ID tracking |
| `mbus_event_post_generic` | `c896e6f0` | Generic event post (called for event_id != 9) |
| `mbus_event_dequeue` | `c896f2f0` | Subscriber dequeues events from its mailbox |
| `mbus_event_init_internal` | `c8970390` | Internal table init (called from kmod init via `c896fa90`) |

## Key data structures

| Symbol | Address | Type | Notes |
|---|---|---|---|
| `mbus_list_head_generic` | `DAT_ffffffffca9bf358` | linked list head | Generic subscribers; iterated `for (lVar = head; lVar != 0; lVar = *(long*)(lVar+8))` |
| `mbus_list_head_av` | `DAT_ffffffffca9c0b40` | linked list head | AV-cache-allocated subscribers |
| `mbus_lock` | `DAT_ffffffffca9bf388` | mutex | type 0, name `"mbus_lock"` |
| `mbus_cv` | `DAT_ffffffffca9bf3a8` | condvar | name `"mbus_cv"` |
| `hdmi_connected_state` | `DAT_ffffffffca9bf350` | u8 | 0=disconnected, 1=connected |
| `hdmi_device_id_counter` | `DAT_ffffffffca9bf354` | u32 | Increments on each CONNECT; wraps at 0x10000 |
| `mbus_active_flag` | `DAT_ffffffffca9c0b30` | u8 | 1 after init, 0 after deinit |
| `mbus_kmem_cache` | `DAT_ffffffffca9c0fa8` | kmem cache* | Generic subscribers (0x180 B/obj) |
| `mbus_av_kmem_cache` | `DAT_ffffffffca9c0fb0` | kmem cache* | AV subscribers (0x180 B/obj) |
| `mbus_event_count_total` | `DAT_ffffffffca9c0f94` | u32 | Total queued events; backpressure trigger at >= 0x10 |
| `mbus_event_count_av` | `DAT_ffffffffca9c0404` | u32 | AV-specific count; backpressure at >= 0x20 |

## HDMI connect/disconnect state machine

```
mbus_event_post_hdmi(9, src, ..., new_state, ...)
                │
                ↓
   ┌────────────────────────────────────┐
   │ new_state == 0 (DISCONNECT)        │
   │ ─────────────────────────────────  │
   │ if (already disconnected)          │
   │   printk WARN                      │
   │ hdmi_connected_state = 0           │
   │                                    │
   │ new_state == 1 (CONNECT)           │
   │ ─────────────────────────────────  │
   │ if (already connected)             │
   │   printk WARN, log new device ID   │
   │ hdmi_connected_state = 1           │
   │ hdmi_device_id_counter++ (max 0x10000) │
   └────────────────────────────────────┘
                │
                ↓
       backpressure wait (3 ms × up to 10):
         while (total >= 0x10 || av >= 0x20)
           cv_timedwait(3 ms)
                │
                ↓
       mbus_event_post_generic(9, src, deviceId<<8, 4 B, new_state, ...)
                │
                ↓ broadcasts to all subscribers
       subscriber wakeups → mbus_event_dequeue() → user-supplied callback
```

The `deviceId << 8` shift means subscribers see:
- bits 0-7 = state (0=disconnected, 1=connected)
- bits 8-31 = device ID counter

So a "new connect" event with state=1 + new ID means "fresh hotplug,
reset your state and re-read EDID etc."

## SYSINIT / Eventhandler registration

`mbus_module_op(0)` does these registrations on init:

| EVENTHANDLER name | Sony callback | Linux equivalent |
|---|---|---|
| `system_suspend_phase1` | `c8970da0` | `suspend_late` notifier |
| `system_resume_phase1` | `c8970dd0` | `resume_early` notifier |

These are standard FreeBSD `EVENTHANDLER_REGISTER` patterns — Sony
saves the cookie in `DAT_ca9c0fa0` / `DAT_ca9c0f98` for later
deregistration via `EVENTHANDLER_DEREGISTER(eh_lists, cookie)`.

## Other event IDs (TODO: enumerate)

Only `event_id == 9` (HDMI) is decoded so far. The generic post
function `c896e6f0` is called for everything else; cross-referencing
its callers in OTHER modules (gc, audioout, dce) would reveal the
full event ID map.

Educated guesses based on PS4 device layout:
- `1` = USB hotplug?
- `2` = SATA HDD?
- `9` = HDMI ✅ confirmed
- `10/11` = audio output device change?
- `12+` = camera, controller, etc.

## Open questions / TODOs

1. **Find the event_id constants** — should be #defines in mbus.h
   or in subscribers. Look at xrefs into the address range of
   `mbus_event_post_generic` from non-mbus modules.
2. Decode the 0x180-byte subscriber struct. Fields probably:
   - subscriber callback function pointer
   - subscriber name (for debug)
   - linked list next/prev (offsets +0, +8 confirmed)
   - flags (+0x50 has bits — bit 3 checked, possibly "stopped/dead")
   - per-subscriber state
3. Map who CALLS `mbus_event_post_hdmi(9, ...)` — that's the producer
   side of HDMI events. Likely from `dce` or `hdmi` modules.
4. Map who CALLS `mbus_subscribe(...)` — those are HDMI listeners.
   Audio (audioout) and AV control (av_control) should be there.

## Linux equivalent

For HDMI hotplug specifically:
- Sony: mbus → producers post, subscribers register/dequeue
- Linux: DRM connector status change → `drm_kms_helper_hotplug_event`
  → userspace via `udev` `add`/`remove` events

For arbitrary cross-module event notification:
- Sony: mbus generic post/subscribe
- Linux: `notifier_chain_register` / `blocking_notifier_call_chain`,
  or `eventfd`, or `netlink_uevent`, depending on the use case

No part of mbus needs porting to Linux — Linux has equivalent
primitives that mainline drivers (DRM, ALSA, etc.) already use.
