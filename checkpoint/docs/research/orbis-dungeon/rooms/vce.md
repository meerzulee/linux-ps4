# Room: vce — Video Compression Engine (encoder)

**Source paths embedded:**
- `sys/internal/modules/vce/kmd_os_wrapper.c` @ string `c8cb4a28`
- `sys/internal/modules/vce/sce_gpkmd.c` @ string `c8cb4a80`

**Function address ranges (heuristic):**
- Module init / state mgmt: ~`c88fdf30..c88fefff`
- Per-chip bring-up (Baikal): ~`c88fe160..` (TBD)
- Per-chip bring-up (other / Gladius): ~`c88fc8e0..` (TBD)

## What this room does

VCE = **Video Compression Engine**. The H.264/H.265 encoder block on
the AMD Liverpool/Baikal SoC. PS4 uses this for:
- "Share" feature (game capture and broadcasting)
- PlayStation Now streaming (encoding game frames to send over the
  network to the player's device)
- Remote Play (encoding game frames for cross-device streaming)

It's the **mirror image of UVD** (decoder ↔ encoder), and the kernel
module structure is similar but slightly larger because Sony exposes
more lifecycle hooks (9 callbacks vs UVD's smaller set).

## Why it matters for Linux on PS4

🔍 **Indirectly** — by understanding VCE's bring-up flow we can
cross-check what we tried for UVD. If VCE bring-up DOES work on Linux
and uses the same structural patterns we replicated for UVD, that
would be a strong signal that UVD's gate is something specific (chip
state) rather than a structural error in our approach.

For a primary Linux user feature, VCE is lower priority — you don't
need video encode for desktop use; software encode (libx264) is fine.
Compare to UVD where hardware decode ENABLES things like 4K video
playback on the PS4's underpowered Jaguar CPU.

## Function map (first-pass)

### Module lifecycle

| Sony function | Address | Purpose |
|---|---|---|
| **`vce_module_op`** | `c88fdf30` | Module init (op=0) / deinit (op=1) |
| `vce_alloc_module_struct` | `c88fd010` | Allocate the module-handle struct |
| `vce_alloc_state_struct` | `c88fd060` | Allocate 0x158-byte VCE state |
| `vce_init_mutex` | `c88fd110` | Init "vce lock" mutex |
| `vce_init_ih_lock` | `c88fd130` | Init "vce ih lock" mutex |
| `vce_alloc_ctx_memory` | `c88fd5e0` | Init "vce context memory" cache |
| `vce_helper_281` | `c88fd180` | (assertion-style helper, refs source path) |
| `vce_helper_150` | `c88fd150` | (assertion-style helper) |
| `vce_reg_read_xx` | `c88fd280` | Read a hardware register |
| `vce_reg_write_xx` | `c88fd290` | Write a hardware register |

### IP block callbacks (function pointers at +0x108..+0x148)

These are stored in the VCE state struct at offsets matching mainline
amdgpu's `struct amd_ip_funcs`:

| Offset | Function | Likely purpose (mainline naming) |
|---|---|---|
| `+0x108` | `c88fe430` | `early_init` (probe) |
| `+0x110` | `c88fe460` | `sw_init` |
| `+0x118` | **`c88fe490`** | `hw_init` — **dispatches to Baikal vs Gladius** |
| `+0x120` | `c88fe520` | `sw_fini` |
| `+0x128` | `c88fe560` | `hw_fini` |
| `+0x130` | `c88fe5a0` | `suspend` |
| `+0x138` | `c88fe5d0` | `resume` |
| `+0x140` | `c88fe620` | `set_clockgating_state` |
| `+0x148` | `c88fe630` | `set_powergating_state` |

### `vce_hw_init` chip dispatch (`FUN_c88fe490`)

```c
hw_init(...) {
    chip = get_chip_family() & 0xffffff80;
    if (chip == 0x740f00) {       // Baikal class
        return vce_hw_init_baikal(...);    // FUN_c88fe160
    } else {                       // Gladius class
        return vce_hw_init_gladius(...);   // FUN_c88fc8e0
    }
}
```

🎯 **`0x740f00` is Sony's Baikal chip family signature.** This is a
useful cross-check against our UVD work — UVD also has a Baikal vs
Gladius dispatch. Same "chip variant 1" we saw in
`uvd_vcpu_start_dispatch` corresponds to the same `0x740f00` signature
internally.

## Init flow

```
vce_module_op(arg, op=0):
  1. Read register 0xf802, set bits 0+2 (vce clock enable bits)
     → val = read(0xf802); write(0xf802, val | 5)
     This is the GFX-side "VCE clock-enable" bit pattern, similar to
     UVD's 0x1401 bit 3.
  2. Probe via FUN_c88fe430() (early_init)
     If returns != 1, abort with err 0x13 (EINVAL)
  3. Allocate module struct DAT_ca8bcbb0 with name DAT_c8cb4aea
  4. Allocate 0x158-byte state struct via "vce context memory" cache
  5. Init "vce lock" mutex at state+0x10
  6. Initial state fields:
     +0x30..+0x68: zeros
     +0x70: 0x100000000 (some "first time" flag in upper word)
     +0x108..+0x148: 9 callback pointers
  7. Call FUN_c88fd4b0(state+0x80) — likely init "vce ih lock"
  8. Store state ptr at module->+0xa8

vce_module_op(arg, op=1):
  - Tear down: destroy mutex, free state, clear pointer
```

## VCE state struct (0x158 bytes)

| Offset | Field |
|---|---|
| `+0x00..+0x0F` | Module name reference (16 B) |
| `+0x10..+0x7F` | "vce lock" mutex |
| `+0x30..+0x68` | Initial-zero state (likely PHY counters / queue heads) |
| `+0x70` | 64-bit flag word, init = `0x100000000` |
| `+0x78` | Reserved |
| `+0x80..+0x107` | "vce ih lock" interrupt-handler mutex (`c88fd4b0` init) |
| `+0x108..+0x148` | 9 IP-block-funcs callbacks (early_init...set_powergating) |

## VCE interrupt-handler debug strings

From printk format strings near the source:

```
"vce_st:%d sw_st:%d curbuf:%d buttag:%d curline:%d nextbuf:%d\n"
"[%d] act:%d sw:%d vce:%d over:%d dis:%d new:%d st:%d mode:%d tag:%2d nxt:%d line:%d ..."
"[vce]          int_en:%d int_ack:%d slice_int_en:%d vce_lc:%d slice:%d\n"
```

These reveal VCE's runtime state model:
- `vce_st` — VCE engine state
- `sw_st` — software-side state (mirrors HW)
- `curbuf` / `nextbuf` — current/next encoder output buffer index
- `buttag` — buffer tag (counter for completion match)
- `curline` — current scan-line being encoded (for partial frames)
- `mode` — encoder mode (H.264 vs H.265 vs other)
- `int_en` / `int_ack` — interrupt enable / ack registers
- `slice_int_en` — per-slice interrupt enable
- `vce_lc` — VCE loop counter

## Cross-reference to UVD findings

| Concept | UVD | VCE |
|---|---|---|
| Chip-variant dispatch | `uvd_vcpu_start_dispatch` (variants 1=Baikal, 2=Gladius) | `vce_hw_init` `(chip == 0x740f00) ? Baikal : Gladius` |
| Per-variant prep function | `uvd_vcpu_prep_baikal` (clear bit 0 of `mmUVD_CGC_CTRL`) | TBD — likely also has a CGC clear |
| Per-variant start function | `uvd_vcpu_start_baikal` | `vce_hw_init_baikal` (`c88fe160`) |
| Init "module" struct | (similar pattern in UVD's `uvd_kmd_module_op`) | `vce_module_op` |
| 0x158 byte state struct | UVD's is similar size | confirmed 0x158 |
| Mutex names | `"sceKmd mutex"` (UVD KMD) | `"vce lock"`, `"vce ih lock"`, `"vce context memory"` |
| GFX-side clock enable | UVD: `0x1401 bit 3` | VCE: `0xf802 bits 0+2` |

**Observation:** VCE init uses GFX register `0xf802` (not the same as
UVD's `0x1401`). On AMD CIK, register `0xf802` is in the GFX/SMC range
— possibly `mmGRBM_GFX_INDEX` or a clock-gating register. The "set bits
0+2" pattern matches "enable VCE clock + enable VCE_PG (power gating)
exit".

## Open questions / TODOs

1. **Decompile `vce_hw_init_baikal` (`c88fe160`)** — that's the
   actual VCE bring-up sequence. Cross-reference against UVD's
   `uvd_vcpu_start_baikal` to spot any patterns we missed.
2. **Map register `0xf802`** — GFX side. The "set bit 5" pattern
   (val | 5 = bits 0+2) probably enables VCE clock and disables VCE
   power gating. Confirm by reading mainline amdgpu's VCE init code
   for Bonaire (mmCC_GFX_PIPE_INSTANCE / similar).
3. **Find the userland API surface** — `sce_gpkmd.c` (string at
   `c8cb4a80`) has no xrefs visible. Either it's referenced indirectly
   (via syscall table) or via a different magic. Likely the encoder
   IOCTLs are similar magic to UVD's `0x83` or `0x84`.
4. **Decode the 11 printk format strings** for full state-machine
   semantics.

## Linux equivalent

| Sony VCE | Linux mainline |
|---|---|
| `vce_module_op` (init/deinit) | `amdgpu_module_load`'s VCE block init |
| 9 IP block funcs | `struct amd_ip_funcs` in amdgpu (Bonaire VCE = `vce_v2_0.c`) |
| `vce_hw_init_baikal` | `vce_v2_0_start_pll` + `vce_v2_0_resume` chain |
| Encoder ring submission | `amdgpu_vce_ring_emit_ib` |
| User API | VA-API → libva → mesa amdgpu winsys → DRM amdgpu → kernel VCE |

For Linux on PS4: mainline amdgpu has VCE 2.0 driver for Bonaire-class.
Should work in principle once amdgpu probes successfully. Same caveat
as UVD: SMU clock state set by Sony's runtime might not be replicable.

If we ever want Linux video encode on PS4, the test path:
1. Get amdgpu probing successfully (currently blocked by UVD failure;
   A18 soft-fail planned)
2. Try `vainfo` to see if VAAPI exposes VCE encoders
3. If so, encode a test stream with `gst-launch ! vaapih264enc`

## Connections to other rooms

- **gc** (graphics compositor): VCE shares VM contexts and ring
  infrastructure with gc.
- **uvd**: sister module; both follow Sony's chip-variant dispatch
  pattern.
- **sdma**: VCE uses SDMA for moving encoded frames around.
