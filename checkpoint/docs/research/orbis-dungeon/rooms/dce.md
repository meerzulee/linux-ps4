# Room: dce — Display Controller Engine

**Source paths embedded:**
- `sys/internal/modules/dce/dce.c` @ string `c8bd3e71`
- `sys/internal/modules/dce/scanin.c` @ string `c8bd4887`
- `sys/internal/modules/dce/flip.c` @ string `c8bd4ebc`
- `sys/internal/modules/dce/ih.c` @ string `c8bd5b5a`
- `sys/internal/modules/dce/ih_def.c` @ string `c8bd5c02`
- `sys/internal/modules/dce/scanin_capture/scanin_capture.c` @ string `c8bd622a`
- `sys/internal/modules/dce/memdce.c` @ string `c8bd628c`

**Function address ranges (heuristic):**
- `dce.c`: ~`c88a6f40..c88a91b3`
- `flip.c`: ~`c88b2050..c88c4799`
- `ih.c`: ~`c88c5470..c88c5970`

## What this room does

DCE = **Display Controller Engine**. This is AMD's Display block in the
Liverpool/Baikal SoC — handles framebuffer scanout, page flip, vsync,
hardware cursor, etc. Equivalent to the `amdgpu_dm` / DC layer in
mainline amdgpu.

Three primary roles:
1. **Per-process DCE contexts**: each renderer (game, compositor) gets
   a `dce_ctx` struct that owns scanout buffers and a flip queue.
2. **Page flip queue management**: queue a future framebuffer to display
   on next vsync, with optional "wait for fence" sync.
3. **Display interrupt routing**: dispatches DCE-generated IH packets
   (vsync, scanout-line, mode-change events) to subscribed handlers.

Plus auxiliary:
4. **scanin_capture**: hardware screen-capture path (PS4's "Share"
   button screenshot).
5. **memdce**: memory-domain helpers for DCE-private buffers.

## Why it matters for Linux on PS4

**Indirectly relevant.** Mainline amdgpu's `dc/` directory and the
`drm_atomic_helper_*` machinery handle the same hardware. We don't
need to port Sony's DCE module — but understanding its **flip queue
semantics** could help if we hit issues with vsync timing on PS4
specifically.

The `ih.c` (interrupt handler) decode is also useful: confirms PS4's
IH packet uses the standard `client_id (16 bits)` + `src_id (8 bits)`
layout that mainline amdgpu expects. So mainline's IH ring code
should work unchanged on PS4 hardware.

## Function map (first-pass)

### dce.c — context lifecycle

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `dce_helper_a` | `c88a6f40` | Internal helper (string xref) |
| `dce_helper_7040` | `c88a7040` | Internal helper |
| `dce_helper_7250` | `c88a7250` | (cleanup variant) |
| `dce_helper_7440` | `c88a7440` | Status query |
| `dce_helper_7e10` | `c88a7e10` | (referenced from refcount paths) |
| `dce_helper_7e90` | `c88a7e90` | (variant) |
| `dce_helper_7f20` | `c88a7f20` | Param-taking helper |
| `dce_helper_8020` | `c88a8020` | (variant) |
| `dce_helper_80c0` | `c88a80c0` | (variant) |
| `dce_helper_81c0` | `c88a81c0` | (variant) |
| `dce_helper_82c0` | `c88a82c0` | (variant) |
| `dce_helper_83d0` | `c88a83d0` | (variant) |
| `dce_helper_84f0` | `c88a84f0` | Larger handler (5 PARAMs) |
| `dce_helper_87e0` | `c88a87e0` | **12 string xrefs — central function** |
| **`dce_ctx_destroy`** | `c88a8f60` | Per-context refcount-drop + cleanup. Decrements ref at +0x3c, frees flip queue at +0x70, removes from global list at `DAT_ca7f6390`, frees the kmem object. |

### flip.c — page flip queue

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `flip_helper_a50` | `c88b4a50` | Internal |
| **`flip_emit`** | `c88b4bb0` | Submit flip request |
| `flip_finish` | `c88b4ce0` | Complete one flip |
| `flip_dispatch` | `c88b4db0` | **Major dispatcher** (called from dce_ctx_destroy too) |
| `flip_helper_5090` | `c88b5090` | Free flip context |
| **`flip_main_handler`** | `c88b5190` | **VERY LARGE function** — main flip operation handler |
| `flip_helper_5c50` | `c88b5c50` | Variant |
| `flip_helper_6060` | `c88b6060` | Internal |
| `flip_helper_63a0` | `c88b63a0` | Internal |
| `flip_helper_6580` | `c88b6580` | Internal |
| `flip_helper_6650` | `c88b6650` | Internal |
| `flip_helper_6910` | `c88b6910` | Internal |
| `flip_helper_6f20` | `c88b6f20` | Internal |
| `flip_helper_6ff0` | `c88b6ff0` | **Major function — likely vsync handler or queue walker** |
| `flip_helper_2050` | `c88b2050` | Internal |
| `flip_helper_20d0` | `c88b20d0` | Internal |
| `flip_helper_2750` | `c88b2750` | Internal |
| `flip_helper_32f0` | `c88c32f0` | Internal |
| `flip_helper_3530` | `c88c3530` | Internal |
| `flip_helper_35d0` | `c88c35d0` | Internal |
| `flip_helper_3960` | `c88c3960` | Internal |
| `flip_helper_4650` | `c88c4650` | Internal |

### ih.c — interrupt handler

| Sony function | Address | Purpose |
|---|---|---|
| **`ih_dispatch_packet`** | `c88c5470` | Reads IH packet client_id + src_id, looks up source, increments pending count |
| `ih_helper_5550` | `c88c5550` | Helper (sub-dispatch?) |
| `ih_register_source` | `c88c57d0` | Register a source for an IH client_id+src_id |
| `ih_unregister_source` | `c88c5870` | Unregister a source |
| `ih_query_source` | `c88c5900` | Query state of a registered source |

### Ancillary functions (TBD)

- `scanin.c` — likely IOCTL surface for "set scanout buffer"
- `scanin_capture.c` — Share-button screenshot path
- `memdce.c` — memory helpers
- `ih_def.c` — IH source ID definitions table

## Per-context data structure (`dce_ctx`)

From `dce_ctx_destroy` (`c88a8f60`):

| Offset | Field |
|---|---|
| `+0x08` | parent device pointer (used in cleanup `*(*ctx+8) + 0xb0`) |
| `+0x3c` | refcount (decremented; cleanup runs at 0) |
| `+0x40` | mutex (passed to `mtx_destroy` equivalent) |
| `+0x70` | linked-list head: queued flip nodes |
| `+0x78` | next pointer (in global DCE list) |
| `+0x80` | misc state (passed to flip helper at `c88b5090` during cleanup) |

Flip queue nodes (at +0x70 list):
- `+0x00..+0x60c` : flip-specific state
- `+0x620` : kmem allocation cookie (freed via `c83a56e0(ptr, &DAT_c9e6edf0)`)
- `+0x628` : next pointer

## IH packet format (confirmed standard AMD)

```
ih_packet (8 bytes minimum):
  bits  0-39 : data / vector-specific
  bits 40-47 : src_id   (entry point within client)
  bits 48-63 : client_id (subsystem ID)
```

Lookup is via `FUN_c88c64c0(client_id, src_id)` returns a source index
into the global IH source table. Negative = unregistered (returns 9 =
ECHILD), out of range returns 0x16 (EINVAL).

This **matches mainline amdgpu's IH packet layout** — `amdgpu_ih.c`
parses the same fields. So mainline's IH ring code Just Works on PS4.

## Key data structures

| Symbol | Address | Purpose |
|---|---|---|
| `dce_global_lock` | `DAT_ca7f60c8` | Global DCE mutex (protects list at `DAT_ca7f6390`) |
| `dce_clear_lock` | `DAT_ca7f6318` | "dceclear" semaphore — held during cleanup |
| `dce_clear_sem` | `DAT_ca7f6398` | 0/1 flag protected by `dce_clear_lock` |
| `dce_ctx_list_head` | `DAT_ca7f6390` | Linked list of all open DCE contexts |
| `ih_lock` | `DAT_ca8622e0` | IH source-table mutex |
| `ih_source_table` | `DAT_ca862308` | Pointer to source table (16 bytes per entry) |
| `ih_source_count` | `DAT_ca862300` | Total registered sources |

## Open questions / TODOs

1. **Find the dce_ioctl entry** — likely in scanin.c or dce.c around
   the larger functions. Probably called from cdev's d_ioctl.
2. **Map flip_main_handler (`c88b5190`)** in detail — it's massive
   (~0x1000 bytes). Likely has the page-flip submit syscall logic.
3. **IH source ID table** — `ih_def.c` has the actual table. Find the
   data-section symbol for `ih_def_table`. Useful for cross-checking
   against mainline `amdgpu_ih.h` enum.
4. **Cross-reference**: who calls `ih_register_source`? Other modules
   (uvd, vce, scanin) register their interrupt handlers via this.
   Maps the full IH source ID space.
5. **scanin_capture** — for Share-button capture, would tell us how
   Sony pulls a framebuffer copy without disturbing the active
   scanout. Could inform a Linux equivalent if we ever want
   `/dev/fb0`-style capture on PS4.

## Linux equivalent

| Sony DCE | Linux mainline |
|---|---|
| `dce_ctx` | `struct drm_file` (per-process) + `drm_framebuffer` |
| Flip queue | `drm_atomic_state` + `drm_atomic_helper_commit_planes` |
| `ih_dispatch_packet` | `amdgpu_ih_process()` |
| `ih_register_source` | `amdgpu_irq_add_id()` |
| `scanin_capture` | DRM dumb-buffer + `drmModeAddFB` |

For our PS4 Linux port, no DCE-specific work needed. Mainline
amdgpu's DC/atomic code handles all of this once amdgpu probes
successfully.

The IH layout confirmation is the takeaway: **mainline's IH parsing
code is correct for PS4 hardware.** Our existing UVD IH handler debug
work (which saw "VM fault vmid 4 from UVD client 0x55564400") was
parsing the same `client_id 0x55564400 = 'UVD' + src_id` packet that
this Sony code parses — confirms our interpretation was right.
