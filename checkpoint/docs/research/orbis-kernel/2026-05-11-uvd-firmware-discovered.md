# Sony's UVD firmware found in Orbis kernel — v72 candidate fix (2026-05-11)

**TL;DR:** Sony's PS4 12.02 kernel embeds UVD firmware as 3 raw ucode
blobs (one per chip rev: Liverpool-early, Liverpool-late/**Baikal**,
Gladius), each ~230-340 KB. **The Baikal blob is version 1.101.42** —
36+ minor revisions ahead of the legacy 1.64 firmware we shipped in v71's
initramfs. That mismatch is the leading hypothesis for v71's "UVD not
responding, giving up" ring-test failure.

We extracted all three blobs from `orbis-12.02.elf`, wrote a wrapper tool
that adds a mainline-compatible `common_firmware_header`, and produced
`liverpool_uvd_baikal_wrapped.bin` — drop-in replacement for
`/lib/firmware/amdgpu/liverpool_uvd.bin` in the initramfs.

## Sony's UVD KMD lifecycle (Ghidra RE map)

Reverse-engineered from `orbis-12.02.elf` (kbase `0xffffffffc839c000`,
md5 `13b07d9abb21f12ed5506903a44159e1`):

```
uvd_kmd_module_op(int op)               @ 0xffffffffc88f6270
   ├── op=0: INIT
   │    ├── alloc module struct            (0x180 bytes)
   │    ├── alloc UVD context              (0x35c8 bytes)
   │    ├── get_chip_family()              @ 0xffffffffc8572e10
   │    │     reads cached CPUID, masks lower 4 bits (stepping)
   │    │     0x710f00..0x710f2f → ctx[0x4c] = 0 (Liverpool early)
   │    │     0x710f30..         → ctx[0x4c] = 1 (Late Liverpool = BAIKAL)
   │    │     0x740f00..0x740f7f → ctx[0x4c] = 2 (Gladius)
   │    ├── mutex_init(ctx, "Uvd kmd lock")
   │    ├── uvd_kmd_hw_init(rev)        @ 0xffffffffc88f6bc0
   │    │     mutex_init("sceKmd mutex")
   │    │     register_irq(0x7c, FUN_c88f6ca0, &state)  ← IRQ 124 = UVD
   │    │     register_irq(0xfffffff0, FUN_c84826c0,  ...)  ← ???
   │    └── uvd_kmd_hw_init_stage2(ctx)  @ 0xffffffffc88f8cf0
   │          uvd_alloc_region(0x1e0000, 3, ...)  ← 1920 KB (FW target)
   │          uvd_alloc_region(0x124000, 0, ...)  ← 1168 KB (UVD heap)
   │          uvd_alloc_region(0x4000,   0, ...)  ←   16 KB (msg queue)
   │          memcpy(region1, firmware_blob[rev], firmware_size[rev])
   │
   └── op=1: TEARDOWN
        ├── uvd_kmd_hw_fini(rev)       @ 0xffffffffc88f6cc0
        ├── mutex_destroy
        └── FUN_c88f8ed0(ctx)               (final cleanup)
```

**Important:** none of these functions issue UVD MMIO register writes.
The actual VCPU power-on sequence is *not in the boot path* — it's lazy,
triggered by the first decode-job ioctl from userspace (`libSceVideoDec`).
So v72 only needs the firmware to be load-able; the VCPU starts when
something tries to decode. If our wrapped firmware works, mainline's
`uvd_v4_2_start()` reset/start sequence will succeed because it'll be
talking to a VCPU that recognizes the ucode it loaded.

## Per-chip UVD firmware blobs

| rev | VA in kernel       | File offset in ELF | Size                  | Chip                       | Extracted to                            |
|-----|--------------------|--------------------|-----------------------|----------------------------|-----------------------------------------|
| 0   | `0xc8c303e0`       | `0x8943E0`         | `0x37bb0` (228,272 B) | Liverpool early CUH-10xx   | `liverpool_uvd_rev0.bin`                |
| **1** | **`0xc8c67ff0`** | **`0x8CBFF0`**     | **`0x4ca38` (313,912 B)** | **Late Liverpool = BAIKAL** | **`liverpool_uvd_baikal.bin`**      |
| 2   | `0xc8bdb240`       | `0x83F240`         | `0x5515c` (348,508 B) | Gladius CUH-2xxx/7xxx      | `liverpool_uvd_gladius.bin`             |

The Baikal blob's identity is confirmed by the string banner at
`0xc8c67f70` (= `blob_addr - 0x80`): `[ATI LIB=UVDFW,1.101.42]`.

Sony's kernel stores the ucode raw — no header, no padding, no version
metadata in-band. Their `uvd_kmd_hw_init_stage2` just `memcpy`s straight
into VRAM. Mainline AMDGPU, in contrast, requires a
`common_firmware_header` (32 bytes) followed by 224 bytes of padding,
followed by the ucode. We bridge that gap with the wrapper tool below.

## Mainline `common_firmware_header` format (reference: shipped 1.64 firmware)

From `src/6.x-baikal/drivers/gpu/drm/amd/amdgpu/amdgpu_ucode.h:28-39`:

```c
struct common_firmware_header {
    uint32_t size_bytes;             /* size of entire file */
    uint32_t header_size_bytes;      /* = 0x20 (size of this struct) */
    uint16_t header_version_major;   /* = 1 */
    uint16_t header_version_minor;   /* = 0 */
    uint16_t ip_version_major;       /* = 4   (UVD 4.2 for Liverpool) */
    uint16_t ip_version_minor;       /* = 2 */
    uint32_t ucode_version;          /* packed, see below */
    uint32_t ucode_size_bytes;       /* size of ucode payload */
    uint32_t ucode_array_offset_bytes; /* typically 0x100 */
    uint32_t crc32;                  /* zlib.crc32 of payload */
};
```

`ucode_version` packing (per `amdgpu_uvd.c:275-281`):

| Byte | Bits   | Field         | Read by                                                           |
|------|--------|---------------|-------------------------------------------------------------------|
| 3    | 24..31 | version_major | `(ucode_version >> 24) & 0xff`                                    |
| 2    | 16..23 | revision      | (not parsed by mainline; free for our use)                        |
| 1    |  8..15 | version_minor | `(ucode_version >>  8) & 0xff`                                    |
| 0    |  0.. 7 | family_id     | `ucode_version & 0xff` — UVD on Bonaire-class wants `9`           |

The reference v1.64 firmware we shipped in v71 has
`ucode_version = 0x01804009`:

```
major=1, rev=0x80 (unused), minor=64 (0x40), family_id=9
→ "Found UVD firmware Version: 1.64 Family ID: 9"  (matches v71 boot)
```

## Wrap format for Sony's Baikal blob

Synthesizing the header for Sony's 1.101.42 ucode, keeping family_id=9
(so mainline accepts it on Liverpool, which is Bonaire-class UVD 4.2):

```
size_bytes              = 0x4cb38   (0x100 preamble + 0x4ca38 body)
header_size             = 0x20
header_version          = 1.0
ip_version              = 4.2       (UVD 4.2)
ucode_version           = 0x012a6509
  major=1, rev=42 (0x2a), minor=101 (0x65), family_id=9
  → "Found UVD firmware Version: 1.101 Family ID: 9"
ucode_size_bytes        = 0x4ca38
ucode_array_offset      = 0x100
crc32(body)             = 0xa465ba07
```

Generated artifact:

```
file: checkpoint/docs/research/orbis-kernel/liverpool_uvd_baikal_wrapped.bin
size: 314,168 bytes
md5:  cbfa0c01d2d365bcd318f0a1834598ce
```

Reproduce with:

```
./tools/orbis-kernel-dumper/wrap-uvd-firmware.py \
    --in  checkpoint/docs/research/orbis-kernel/liverpool_uvd_baikal.bin \
    --out checkpoint/docs/research/orbis-kernel/liverpool_uvd_baikal_wrapped.bin \
    --version 1.101.42 \
    --family-id 9
```

(The two `.bin` outputs are gitignored — see `checkpoint/docs/research/orbis-kernel/*.bin` rule in root `.gitignore`. Anyone reproducing this work runs `tools/orbis-kernel-dumper/` themselves to dump the kernel, then runs the wrapper.)

## v72 test plan

Single change vs v71 (which is on `wip/uvd-vce-poc` branch already):

1. **Replace** `lib/firmware/amdgpu/liverpool_uvd.bin` inside
   `output/initramfs.cpio.gz` with our wrapped Baikal blob.
2. Build kernel from `wip/uvd-vce-poc` (so v70 IP-block adds + v71
   firmware-name patch are in series).
3. Stage to USB.
4. Boot via PSFree-Enhanced → Payload Guest → linux-1024mb.bin.

Expected first-pass dmesg vs v71:

| v71 (failed)                                                       | v72 expected                                                            |
|---|---|
| `detected ip block 6 <uvd_v4_2>`                                   | ditto                                                                  |
| `Found UVD firmware Version: 1.64 Family ID: 9`                    | **`Found UVD firmware Version: 1.101 Family ID: 9`** ← key signal      |
| `uvd_v4_2_start: UVD not responding, trying to reset the VCPU` ×10 | (should NOT appear if firmware version was the issue)                  |
| `*ERROR* ring uvd test failed (-110)`                              | (should NOT appear)                                                    |
| `hw_init of IP block <uvd_v4_2> failed -110`                       | (should NOT appear)                                                    |
| `probe with driver amdgpu failed with error -110`                  | (should NOT appear; HDMI should light up)                              |

If the wrapped firmware works, we'll see UVD reach `hw_init` success,
amdgpu probe succeeds, HDMI lights up, **and `/dev/dri/renderD128`
appears** — which is the first time Linux on PS4 has had hardware video
decode.

If it still fails, the message pattern will tell us where:
- "Can't validate firmware" → wrapper bug (header field wrong)
- Same UVD-not-responding pattern → firmware version wasn't the issue;
  back to RE of the actual VCPU power-on sequence
- A different failure mode → progress, new investigation lead

## Ghidra rename map (for posterity)

If the Ghidra project at `/home/meerzulee/Work/ghidra/orbis-ps4-dump` is
lost or someone reproduces the work, these are the renames we made:

| Address                  | Name                       | Notes |
|--------------------------|----------------------------|-------|
| `0xffffffffc8572e10`     | `get_chip_family`          | masks lower 4 stepping bits off cached CPUID |
| `0xffffffffc867c3e0`     | `printk`                   | Sony's format-string logger |
| `0xffffffffc8762ba0`     | (provisional) GFX status snapshotter — entry #6 of diagnostic vtable |
| `0xffffffffc8762ec0`     | `get_lvp_uvd_status`       | UVD status snapshotter (entry #9 of diagnostic vtable @ 0xc9ca9e48) |
| `0xffffffffc8762fb0`     | `get_lvp_vce_status`       | VCE status snapshotter (entry #10) |
| `0xffffffffc8868ef0`     | `gpu_reg_read`             | GPU MMIO read primitive (sys/internal/modules/gc/vm.c); index/data dispatch |
| `0xffffffffc88f6270`     | `uvd_kmd_module_op`        | op=0 init, op=1 teardown (sce_gpkmd.c) |
| `0xffffffffc88f6bc0`     | `uvd_kmd_hw_init`          | mutex + IRQ 124 registration |
| `0xffffffffc88f6cc0`     | `uvd_kmd_hw_fini`          | mirror of hw_init |
| `0xffffffffc88f8cf0`     | `uvd_kmd_hw_init_stage2`   | alloc 3 regions + memcpy fw blob to region1 |
| `0xffffffffc88f94e0`     | `uvd_alloc_region`         | GPU memory region allocator |

Diagnostic vtable (read-only status snapshotters) at
`0xffffffffc9ca9da0` → `0xffffffffc9ca9e68` (NULL terminator). ~25
entries × 8 bytes, dispatcher unidentified (likely `sceGpuGetStatus`
syscall handler).

Other interesting addresses (not yet decompiled):

| Address                  | Likely role |
|--------------------------|-------------|
| `0xffffffffc88f6c90`     | UVD timer/teardown callback (set in uvd_kmd_hw_init as global handler) |
| `0xffffffffc88f6ca0`     | UVD top-half ISR (registered for IRQ 124; thin shim to FUN_c85e3b00) |
| `0xffffffffc88f8ed0`     | UVD final teardown (called from uvd_kmd_module_op op=1) |
| `0xffffffffc88f9180`     | optional per-rev teardown (called when ctx[0xd4] != 0) |
| `0xffffffffca8bcb30`     | global `g_uvd_kmd_module` pointer |
| `0xffffffffca8bcb38`     | global `g_uvd_state` (0x70 bytes) |
| `0xffffffffca8bcb68`     | global `g_uvd_state.mutex` ("sceKmd mutex") |

## Follow-up research targets (after v72 test)

1. **Find Sony's VCE firmware** — same kernel, same pattern. Search for
   the VCE banner `[ATI LIB=VCEFW,...]` and apply the wrap tool with
   `--ip-version 2.0` (VCE 2.0 for Liverpool).
2. **Find the lazy VCPU power-on** — if v72 still fails despite correct
   firmware, the actual register sequence Sony uses to start the VCPU
   needs to be located. Likely entry points: `FUN_c88f6ca0` (IRQ
   handler), or trace ioctl→handler dispatch tables for `sceVideoDec*`.
3. **VCE handler table** — `get_lvp_vce_status` at entry #10 of the
   diagnostic vtable suggests a parallel VCE KMD module with the same
   lifecycle shape. Apply this same approach to find `vce_kmd_module_op`,
   etc.
4. **Identify the diagnostic vtable dispatcher** — useful for crash-dump
   tooling and for understanding which userspace syscalls trigger
   per-subsystem status reads.
