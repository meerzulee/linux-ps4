# Room: sdma — System DMA Engine

**Source paths embedded:**
- `sys/internal/modules/sdma/sdma.c` @ string `c8e7787b`
- `sys/internal/modules/sdma/sdma_misc.c` @ string `c8e76f40`
- `sys/internal/modules/sdma/sdma_mini.c` @ string `c8e76fe3`
- `sys/internal/modules/sdma/sdma_context.c` @ string `c8e77a5c`
- `sys/internal/modules/sdma/sdma_hwdep.c` @ string `c8e77450`
- `sys/internal/modules/sdma/sdma_kreader.c` @ string `c8e7722a`
- `sys/internal/modules/sdma/sdma_kreader_device.c` @ string `c8e76e2e`
- `sys/internal/modules/sdma/common/sdma_lib_common.c` @ string `c8e777bc`
- `sys/internal/modules/sdma/common/sceSdmaLib.c` @ string `c8e779ec`

**Function address range:** ~`c8963000..c896d800` (heuristic)

## What this room does

SDMA = **System Direct Memory Access**. Sony exposes the AMD GPU's SDMA
engine as a **general-purpose DMA service** accessible to userspace
processes. Apps can submit copy/fill/scatter operations to SDMA queues
and SDMA handles them in parallel with the CPU.

This is **distinct from amdgpu's SDMA**, which mainline uses internally
for buffer migration. Sony exposes a USER API:
- `libSceSdma.sprx` (userspace) talks to this kernel module
- App allocates an SDMA "context" (per-process queue)
- App posts commands (memcpy, memfill, scatter-gather)
- SDMA fires an interrupt on completion
- App polls or blocks on completion

Used for:
- Video decode post-processing (UVD output → display surface)
- Game streaming compositor (copy frames between BOs)
- PSV cross-process buffer copies
- General memcpy acceleration

## Why it matters for Linux on PS4

**Indirectly relevant.** Mainline amdgpu has SDMA driver support for
the CIK family (`sdma_v2_4.c` covers Bonaire-class which is what
Liverpool's SDMA is). So Linux's amdgpu SHOULD be able to drive the
SDMA engine for its own use (buffer migration etc).

But the **USER-FACING SDMA API** Sony provides is not in mainline. If
we wanted PS4 games on Linux to use SDMA (we probably don't), we'd
need to expose an ioctl wrapper. Not in scope for our port.

Useful takeaway: Sony's SDMA has a 16-slot interrupt ring with two
write/read pointers — that's the hardware queue depth, useful to know
if our amdgpu SDMA hits any timing issues.

## Function map (first-pass)

### sdma.c — core (top-level)

| Sony function | Address | Purpose |
|---|---|---|
| `sdma_module_lock_acquire_wrapper` | `c896a2a0` | Just acquires `DAT_ca9ba9f0` mutex at sdma.c:0x7f |
| `sdma_module_lock_release_wrapper` | `c896a2c0` | Mirror release |
| **`sdma_ih_tasklet`** | `c896a5a0` | **Main interrupt handler tasklet** — walks IH ring, dispatches by packet type |
| `sdma_completion_handler_type1` | `c896a8f0` | "Type 1" packet handler (mutex-protected completion notify) |
| `sdma_completion_handler_type3` | `c896aad0` | "Type 3" packet handler (condvar wakeup at +0x1a8) |
| `sdma_helper_dec_inflight` | `c896ada0` | Decrement in-flight counter |
| `sdma_helper_emit_event` | `c896ae80` | Emit completion event |

### sdma_hwdep.c — HW-dependent submission

| Sony function | Address | Purpose |
|---|---|---|
| **`sdma_hwdep_submit_cmd`** | `c8967150` | **Build and submit one SDMA command packet** (memcpy/fill descriptor → HW ring) |

### sdma_misc.c — misc helpers

| Sony function | Address | Purpose |
|---|---|---|
| `sdma_misc_helper` | `c896d6b0` | Helper called from `sdma_hwdep_submit_cmd` after building packet — likely "ring doorbell" |

## Interrupt handler (sdma_ih_tasklet) state machine

The SDMA hardware writes interrupt packets into a 16-slot ring buffer
at offset 0xB0 of the device struct (16 bytes per entry).

```
device_struct:
  +0x30  : interrupt_count_total       (incremented every IH event)
  +0x38  : interrupt_count_bookkeeping (type 0xF3 only)
  +0x40  : lock (mutex for type 1 path)
  +0x70  : lock (mutex for IH path)
  +0xB0  : IH ring[16] (16 entries × 16 bytes)
  +0x1B0 : write pointer (HW updates)
  +0x1B4 : read  pointer (sw updates)
```

For each entry in the ring (while rd != wr):

```
type_byte = entry[0]  (interpreted as signed char)

if (type_byte == -0x0D = 0xF3): // bookkeeping/heartbeat
    interrupt_count_bookkeeping++
    advance read pointer

else if (type_byte == -0x20 = 0xE0): // completion
    source_id = entry[1] & 0xff
    owner_struct = device[+(source_id * 8)]
    
    packet_op = (FUN_c896d440 → fetches packet metadata)
    switch (packet_op.field_0xF):
      case 0x01: // mutex-locked completion
        atomic_xchg(device+0x40, value | 0x80, 1)
      
      case 0x02: // queue-empty notification
        FUN_c8966940() // generic notify
      
      case 0x03: // stream completion
        if (packet[2] != 0) // optional condvar
          cv_signal(packet[2] + 0x1A8)
    
    FUN_c896d3c0() // ring doorbell / advance HW pointer

advance read pointer: rd = (rd + 1) & 0xF
```

## Command submission (sdma_hwdep_submit_cmd) packet format

`FUN_c8967150(device_struct, cmd_desc, async_flag)` builds an 8 or
16-byte hardware packet:

```
cmd[0] (32 bits):
  bits  0-7  : 0x04  (opcode = COPY?)
  bits  8-15 : reserved/zero
  bits 16-19 : (device->queue_id & 0xF)
  bits 20-31 : reserved

cmd[1..2] (64 bits): source DMA address
              = (cmd_desc.field_8 * 4) + cmd_desc.base

cmd[3] (32 bits):
  bits  0-19 : transfer length (max 1 MB per packet)
  bits 20-31 : flags
```

The packet is then submitted to the SDMA ring via `FUN_c896d6b0` and
the doorbell is rung via `FUN_c896d3c0(device, device[0x34])` where
`device[0x34]` is the queue's HW base address.

If `async_flag != 0`, increments device[0x3D] (pending count) and may
schedule a notification via `FUN_c8966110`.

## Other source files (TODO: full mapping)

| File | Likely role |
|---|---|
| `sdma_mini.c` | "Mini" subset of API — maybe single-shot copy without setup overhead |
| `sdma_context.c` | Per-process SDMA context (queue allocation, lifecycle) |
| `sdma_kreader.c` | Kernel reader — async file-read DMA pattern |
| `sdma_kreader_device.c` | Kernel reader's device interface |
| `common/sdma_lib_common.c` | Code shared with libSceSdma.sprx userspace |
| `common/sceSdmaLib.c` | Kernel-side stubs for `sceSdma*` syscalls |

## Linux equivalent

Mainline amdgpu's SDMA support for Liverpool's CIK family is in
`drivers/gpu/drm/amd/amdgpu/sdma_v2_4.c` (Bonaire-class). It handles:
- SDMA ring init
- DMA copy/fill ops for BO migration
- Page table updates

For our PS4 Linux port, this works "out of the box" once amdgpu probes
successfully (currently blocked by UVD's failure, which we worked around
via A17 / soft-fail planned).

We do NOT need to port Sony's user-facing SDMA API. Apps on Linux that
need DMA acceleration use:
- `dma-buf` for cross-driver buffer sharing
- `ioctl(DRM_IOCTL_AMDGPU_BO_LIST)` + `AMDGPU_INFO_DEV_INFO` for direct
  GPU DMA
- `mmap` + memcpy with hugepages for plain memory copy

## Open questions / TODOs

1. Find sdma's SYSINIT entry — should appear in `mi_startup` chain at
   subsystem ~`SI_SUB_DRIVERS` (0x3800).
2. Map the SDMA syscalls: `sceSdmaCreate`, `sceSdmaSubmit`,
   `sceSdmaWait`. They'd be in `common/sceSdmaLib.c`'s functions
   around `c896d7xx..c896d8xx`.
3. Determine queue count: device struct field `[0x34]` is queue base.
   The "& 0xF" mask in submission suggests ≤16 queues.
4. Identify packet opcodes: `cmd[0] & 0xff = 0x04` is "the COPY op".
   What are the other ones? (0x01 = NOP, 0x02 = FENCE, 0x03 = TRAP
   in mainline amdgpu — likely Sony's match.)
5. Cross-reference: does UVD use SDMA for its post-decode display copy?
   If yes, our UVD bring-up might benefit from understanding this path
   too (post-mortem use only — UVD is paused).
