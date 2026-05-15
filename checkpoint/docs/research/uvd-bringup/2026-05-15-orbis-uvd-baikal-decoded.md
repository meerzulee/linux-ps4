# Orbis UVD/Baikal bring-up sequence — fully decoded from 12.02 kernel

**Date:** 2026-05-15
**Author:** Ghidra MCP dig of `orbis-12.02.elf` (Sony FreeBSD kernel, 12.02 retail)
**Status:** 🔥 **Major finding** — flips the SAMU stealth-auth wall conclusion.

---

## Headline

**`uvd_vcpu_start_baikal` (Sony's UVD VCPU start function for our exact
chip variant) does not call `sceSblDriverWriteSmuIx` at all.**

It is pure direct GPU MMIO. No SMU writes. No SBL. No ICC. No SAMU
involvement.

This means the "structural wall" conclusion from sessions 1-4
(`stealth-auth-confirmed.md`, `structural-wall-summary.md`) was a false
negative for the UVD path: we were chasing an SMU bypass that **Sony's
own Baikal UVD code doesn't need**. The 18 failed bring-up iterations
(v70 through v76e) were patching mainline `uvd_v4_2_start` (a Trinity /
Kabini APU recipe) which has the wrong register addresses, the wrong
init order, and is missing Baikal-specific indirect-register writes.

The right move is now: replace mainline `uvd_v4_2_start` with a
faithful port of `uvd_vcpu_start_baikal`. No SAMU work required.

---

## Decoded function map (Sony UVD KMD)

| Sony function | Address | Role |
|---|---|---|
| `uvd_kmd_module_op` | `c88f6270` | Module init/deinit, sets per-chip-rev fields |
| `FUN_c88f6680` | `c88f6680` | Open device for client (state 0→1, calls `FUN_c88f9010`) |
| `FUN_c88f67d0` | `c88f67d0` | Wait/start dispatch (state 2→4 or 5; chip-variant calls `uvd_vcpu_wait_ready`/`FUN_c88f98a0`/`FUN_c88fafe0`) |
| `FUN_c88f68e0` | `c88f68e0` | **Main ioctl dispatch.** Handles `0x20008301` = start, `0x20008302` = stop, `0x4004830b` → 0x20000, `0x4008830c` → `0x300308000`, query/info ops `0x80188304-A` |
| `uvd_kmd_hw_init` | `c88f6bc0` | Module hw_init: install IRQ vector 0x7c → `FUN_c88f6ca0`, init mutex |
| `uvd_kmd_hw_fini` | `c88f6cc0` | Module hw_fini |
| **`uvd_vcpu_start_dispatch`** | `c88f6db0` | **Variant dispatcher** — picks Baikal/Liverpool/Gladius |
| `uvd_vcpu_prep_baikal` | `c88f7490` | Pre-start: clear bit 0 of reg `0x3d2c` |
| `uvd_vcpu_wait_ready` | `c88f74b0` | Post-start ready-poll (0x3d67, 0x3daf, 0x3d3d, 0x3da0 ramp) |
| **`uvd_vcpu_start_baikal`** | `c88f8610` | **The whole VCPU bring-up for our chip** |
| `uvd_kmd_hw_init_stage2` | `c88f8cf0` | Allocate 3 GPU memory regions + memcpy UVD firmware |
| `uvd_alloc_region` | `c88f94e0` | GART allocator, range `0x2000000000..0x2080000000` (128-130 GB) |
| `uvd_vcpu_start_lvp_early` | `c88fa850` | Liverpool-early variant start |
| `uvd_vcpu_start_gladius` | `c88fc140` | Gladius variant start |
| `get_lvp_uvd_status` | `c8762ec0` | Diag: 19 GPU MMIO reads + 1 SBL Read for SMU idx `0xa5` (`uvd_lmi_clean_status`) |
| `get_gl_uvd_status` | `c8528eb0` | Same but for Gladius |

Note `get_*_uvd_status` is the *only* place SBL touches UVD diagnostics
— and it's a **read** of one SMU register (`0xa5`), which SAMU does
allow. Writes are not used in the Baikal UVD path.

---

## `uvd_vcpu_start_baikal` — the exact init recipe

Reference: `decompile_function(0xffffffffc88f8610)` against
`/orbis-12.02.elf` in the `orbis-ps4-dump` Ghidra project.

### Phase A — clock/power-gating release

```c
gpu_reg_set_bits(0x3daf, 0x4);           // RW1S bit 2

// 6× cache control regs, all set to 0x02011002
for (reg of {0x3bd4, 0x3bd5, 0x3bd3, 0x3992, 0x39c5, 0x3993})
    gpu_reg_write(reg, 0x02011002);

gpu_reg_clr_bits(0x3d2a, 0x000fffff & ~0x8);  // clear low bits (mask = ~0xfff00008)
gpu_reg_clr_bits(0x3be4, 0x00001fff);
if (gpu_reg_read(0x398) & 0x40000)            // PG status check
    gpu_reg_clr_bits(0x398, 0x40000);

gpu_reg_set_bits(0x3d98, 0x200);              // mark "init in progress"
gpu_reg_clr_bits(0x3d40, 0x2);
```

### Phase B — IH ring base + LMI tag setup

```c
gpu_reg_write(0x3d6d, 0);
gpu_reg_write(0x3d6f, 0);
gpu_reg_write(0x3d68, 0);
gpu_reg_write(0x3d66, 0x203108);
(void)gpu_reg_read(0x3d77);                   // discard read
gpu_reg_write(0x3d77, 0x10);
gpu_reg_write(0x3d79, 0x040c2040);
gpu_reg_write(0x3d7a, 0);
gpu_reg_write(0x3d7b, 0x040c2040);
gpu_reg_write(0x3d7c, 0);
gpu_reg_write(0x3d7e, 0);
gpu_reg_write(0x3d7d, 0x88);
gpu_reg_write(0x3d68, 0x3dff);
gpu_reg_write(0x3d3c, ctx->per_chip_param & 0xf);  // ctx+0x40
```

`ctx->per_chip_param` (state+0x40) is read in `FUN_c88f6680` from
`gpu_dev+0x134` — a per-chip parameter set by the GPU device probe
(likely PHY lane count or RB count; needs separate dig).

### Phase C — UVD-internal indirect register writes

UVD has its own indirect-register protocol via `0x3d28` (index port)
and `0x3d29` (data port). Sony writes 4 indexes here:

```c
// IDX 0x99 — packed nibble pattern
save = gpu_reg_read(0x3d28);
gpu_reg_write(0x3d28, 0x99);
old = gpu_reg_read(0x3d29);
n = ctx->per_chip_param & 0xf;
gpu_reg_write(0x3d29, (n<<20) | n | (n<<4) | (n<<8) | (n<<12) | (n<<16) | (old & 0xff000000));
gpu_reg_write(0x3d28, save);

// IDX 0x9a — slightly different packing (top bits = full param, not nibble)
save = gpu_reg_read(0x3d28);
gpu_reg_write(0x3d28, 0x9a);
(void)gpu_reg_read(0x3d29);
gpu_reg_write(0x3d29, (param<<28) | n | (n<<4) | (n<<8) | (n<<12) | (n<<16) | (n<<20) | (n<<24));
gpu_reg_write(0x3d28, save);

// IDX 0x162 — 4 nibbles low + preserve top 16
save = gpu_reg_read(0x3d28);
gpu_reg_write(0x3d28, 0x162);
old = gpu_reg_read(0x3d29);
gpu_reg_write(0x3d29, (n<<12) | n | (n<<4) | (n<<8) | (old & 0xffff0000));
gpu_reg_write(0x3d28, save);
```

⚠️ **This indirect-register protocol is Baikal-specific.** Mainline
`uvd_v4_2_start` does not do it. Skipping this is one likely reason
for the 18-iteration bring-up failure.

### Phase D — direct UVD config

```c
gpu_reg_write(0x3da3, n);                     // n = per_chip_param & 0xf
gpu_reg_write(0x3da1, n);
gpu_reg_write(0x3c5f, 0);
gpu_reg_write(0x3c5e, 3);
gpu_reg_write(0x3d82, 0);
gpu_reg_write(0x3d83, 0x7d000);
gpu_reg_write(0x3d84, 64000);                 // 0xfa00
gpu_reg_write(0x3d85, 0x40000);
gpu_reg_write(0x3d86, 0x17a00);
gpu_reg_write(0x3d87, 0x120800);
gpu_reg_set_bits(0x3d98, 0x200);              // re-assert
```

### Phase E — UVD address-space programming

```c
u64 fw_va = ctx->fw_load_va;                  // ctx+0x88 (set during fw load, GART)

// Some hash/index thing
u32 a = FUN_c88f6b70(0x1000);
u32 b = FUN_c88f6b70(0x100);
gpu_reg_write(0x3da9, ((a & 0x1f)) + 0x11010000 + ((b & 0x1f) * 0x100));
gpu_reg_write(0x3dab, 1);

ctx->some_addr_2c = 0x40000000000;            // 4 TB (well above GART top)
ctx->some_addr_24 = 0x40000000000;

gpu_reg_set_bits(0x1401, 0x8);                // SRBM_GFX_CNTL.UVD_EN

gpu_reg_write(0x3c69, fw_va & 0xffffffff);    // UVD_LMI_VCPU_NC_RANGE_LSB?
gpu_reg_write(0x3c68, fw_va >> 32);           //   "                MSB?
gpu_reg_write(0x3da5, 0);
gpu_reg_write(0x3da4, 0);

gpu_reg_clr_bits(0x3da9, 0x10010000);
gpu_reg_clr_bits(0x3da0, 0x1);
```

### Phase F — VCPU release sequence

```c
// UVD-internal IDX 0x9b: clear bit 4 of low byte
save = gpu_reg_read(0x3d28);
gpu_reg_write(0x3d28, 0x9b);
old = gpu_reg_read(0x3d29);
gpu_reg_write(0x3d29, old & 0xffffffef);
gpu_reg_write(0x3d28, save);

gpu_reg_write(0x3dac, 0x10);
gpu_reg_set_bits(0x3dab, 0x3);                // commit

gpu_reg_clr_bits(0x3d98, 0x40000);
gpu_reg_clr_bits(0x3d3d, 0x100);

// UVD reset deassertion ramp (3 stages)
gpu_reg_clr_bits(0x3da0, 0x4);
gpu_reg_clr_bits(0x3da0, 0x8);
gpu_reg_clr_bits(0x3da0, 0x2000);

udelay(16000);                                // 16 ms settle

// Poll 0x3daf bit 1 set, up to 2 seconds
for (int i = -2000000; i; i += 1000) {
    if (gpu_reg_read(0x3daf) & 0x2) {
        // SUCCESS
        gpu_reg_set_bits(0x3d40, 0x2);
        gpu_reg_clr_bits(0x3daf, 0x4);

        ctx->mc_state = gpu_reg_read(0x9e0);  // SRBM_STATUS or similar
        gpu_reg_write(0x9e0, (ctx->mc_state & ~3) + 2);

        (void)gpu_reg_read(0x501);
        gpu_reg_write(0x501, 3);
        return 0;                             // ← success path
    }
    udelay(1000);
}

// FAILED: panic-like trap
printk("[%s@%04X%04X:%08llX]\n", "SCEGPKMD", 0xf0a1, 0x1b3, 2);
```

The success bit is **`0x3daf` bit 1**, polled with 16 ms initial delay
+ 2 s timeout in 1 ms steps. After it sets, write `0x3d40 |= 2`,
clear `0x3daf` bit 2, snapshot `0x9e0`, write `0x9e0 = (snap & ~3) + 2`,
read+write `0x501 = 3`. Done.

This matches roughly the polling pattern our v75 patch tried — but
v75 polled mainline-named registers without the indirect-register
phases C/F and the LMI Phase E. That's why it never set.

---

## Memory layout (`uvd_kmd_hw_init_stage2`)

3 GART memory regions allocated, all from range
`0x2000000000..0x2080000000` (the 2 GB UVD GART window starting at
GPU VA `128 GB`):

| Region | Size | Align | Stored at | Purpose |
|---|---|---|---|---|
| 1 | `0x1E0000` (1.92 MB) | 16 KB | ctx+0x50, +0x58, +0x60 | UVD firmware blob target |
| 2 | `0x124000` (1.16 MB) | 4 KB | ctx+0x70, +0x78, +0x80 | UVD heap / IB stage |
| 3 | `0x4000` (16 KB) | 4 KB | ctx+0x90, +0x98, +0xa0 | Message queue / scratch |
| **total** | **~3.1 MB** | | | |

After allocation, the per-chip-revision UVD firmware blob is `memcpy`'d
into Region 1.

---

## UVD firmware blobs (embedded in Orbis kernel rodata)

`uvd_kmd_hw_init_stage2` dispatches on `ctx->chip_rev` (state+0x4c):

| chip_rev | Chip | FW src in orbis-12.02.elf | Size | Banner |
|---|---|---|---|---|
| 0 | Liverpool-early (CUH-10xx/12xx) | `0xc8c303e0` | `0x37bb0` (226 KB) | (TBD) |
| **1** | **Liverpool-late = BAIKAL** | **`0xc8c67ff0`** | **`0x4ca38` (314 KB)** | **`[ATI LIB=UVDFW,1.101.42]`** |
| 2 | Gladius (PS4 Slim/Pro) | `0xc8bdb240` | `0x5515c` (340 KB) | (TBD) |

⭐ **Our PS4 (Baikal) uses chip_rev=1 / 314 KB / `[ATI LIB=UVDFW,1.101.42]`.**

To extract:

```bash
dd if=/home/meerzulee/Downloads/PS4/Kernel/Retail/1202.elf \
   of=/tmp/uvd_baikal_1.101.42.fw \
   bs=1 skip=$((0xc8c67ff0 - <ELF .rodata file offset>)) count=$((0x4ca38))
```

(The exact file offset = ELF rodata file_offset + (0xc8c67ff0 - rodata_vaddr).
Need a quick `readelf -S` to compute, then we have the firmware as a
plain blob — no SAMU wrapping required, this is unencrypted UVD
microcode.)

This is a clean alternative to the firmware-extraction approach in
`tools/orbis-kernel-dumper/wrap-uvd-firmware.py` (which targeted a
different blob format). Embedded in kernel rodata = far simpler.

---

## What this means for the 18 failed bring-up iterations

| Iteration | What it tried | Why it actually failed |
|---|---|---|
| v70-v75 | Toggle UVD enable bits, mainline `uvd_v4_2_start`, BO size tweaks | Wrong register sequence — mainline targets Trinity APU, not Baikal |
| v76a | Mainline + GART PT writeable | Right direction but missing Phase C indirect writes |
| v76b | Zero LMI ext | Mainline reg name; Sony's path uses 0x3da9 ext setup, not zero |
| v76c-d | Various GMC/PT permutations | All addressing the *symptom* (VM faults) not the *cause* (wrong VCPU init) |
| v76e A18 | Soft-fail (graceful exit) | Pragmatic workaround — kept project moving with software decode |
| SBL phase 1-3 | Build SBL primitives to do SMU writes | **Wrong premise** — Baikal UVD doesn't need SMU writes |
| stealth-auth conclusion | "SAMU silently no-ops SBL writes" | True, but not relevant for UVD bring-up |

The structural-wall summary stands true on its narrow technical claim
(SAMU does drop SBL writes from non-signed contexts), but the inference
("therefore UVD can't work") was wrong — built on the assumption that
Sony's Baikal UVD bring-up needs SMU access. Decompile says it doesn't.

---

## Open questions — RESOLVED in follow-up Ghidra round

### ✅ Q1 — `per_chip_param` (state+0x40, from gpu_dev nested deref)

Source chain: `kmd_state.gpu_dev_ptr = *(*(ioctl_arg + 8) + 0x168);
kmd_state.per_chip_param = u32 at gpu_dev_ptr + 0x134`.

The deref-chain target is the **CAIL chip-info struct** (`gc/cail.c`,
the only `cail.c` source path embedded in the kernel ELF). It has:
- `+0x58` magic word `0x3800000000000003` (type-tag for "is GPU CAIL ctx")
- `+0xc0`/`+0xe0` paired locks (sleep vs spin)
- `+0x110`/`+0x114` use-counters
- `+0x134` the value we want

`+0x134` is treated as a signed int (must be ≥ 0 — `if (signed_int < 0)` errors out)
and is only ever consumed in **its low 4 bits** by UVD bring-up (every site
masks `& 0xf` or shifts as a nibble).

**Pragmatic resolution for the port**: don't chase the CAIL probe path
in Ghidra — the value is 1 nibble. Try `n=4` first (canonical UVD VCPU
parallel-stream / RB count for GCN1), fall back to `n=0xf`, then `n=1`.
Each empirical iteration costs ~10 min of PSFree gauntlet, so 3 attempts
worst case = 30 min. With UART log instrumentation showing the chosen
value vs the hardware response, we'll converge fast.

If empirical fails: chase `cail.c` chip-discovery — search for code that
writes a u32 at `cail_ctx + 0x134`, near a `get_chip_family()` call.
We have 12 callers of `get_chip_family` mapped; it's bounded.

### ✅ Q2 — `ctx->fw_load_va` = `0x300000000` (UVD-internal VA)

Confirmed via `FUN_c88f9010(kmd_state)` (which we decompiled). It
maps the 3 Region buffers into UVD's own VMID space:
- Region 1 (firmware) → UVD-VA `0x300000000`, size `0x1E0000`
- Region 2 (heap) → UVD-VA `0x3001E0000`, size `0x124000`
- Region 3 (msg/ring) → UVD-VA `0x300304000`, size `0x4000`

Total UVD VMID footprint: `0x308000` bytes contiguous starting at
`0x300000000`. Final byte of Region 3 = `0x300307FFF`; the constant
`0x300308000` returned by ioctl `0x4008830c` is the "next-free" UVD VA
that userspace can hand out for IBs.

**For our patch**: write `0x3c69 = 0x00000000` and `0x3c68 = 0x00000003`
(LMI VCPU NC RANGE LSB/MSB) — programming UVD VMID base to `0x3_00000000`.

### ✅ Q3 — chip_rev detection

```c
chip_family = get_chip_family();
if ((chip_family & 0xffffff00) == 0x710f00) {
    if (chip_family < 0x710f30) chip_rev = 0;     // Liverpool-early (pre-Baikal)
    else                         chip_rev = 1;    // Liverpool-late = BAIKAL ⭐
} else if ((chip_family & 0xffffff80) == 0x740f00) {
    chip_rev = 2;                                  // Gladius (Slim/Pro)
} else {
    /* unsupported, bail */
}
```

For our Linux port: hardcode `chip_rev = 1` — we target Baikal exclusively.

### ✅ Q4a — `FUN_c88f6b70` is just `__builtin_ctz()` via De Bruijn LUT

Classic 32-bit De Bruijn sequence trick (constant `0x77cb531`):
- `ctz(0x1000) = 12`
- `ctz(0x100) = 8`

So Phase E reg `0x3da9` always gets the literal:
```
(12 & 0x1f) + 0x11010000 + (8 & 0x1f) * 0x100
= 12 + 0x11010000 + 0x800
= 0x1101080C
```

**For our patch**: just `gpu_reg_write(0x3da9, 0x1101080C);` — no helper.

### ✅ Q4b — `FUN_c88f9010` is the GART-to-UVD-VMID mapper

(See Q2 above.) Wires the 3 Region buffers into UVD's address space
at fixed VAs. After mapping, sets up message-queue pointers:
- `ctx->b0 = ctx->a8 + 0x0`     (region3 base ptr)
- `ctx->c0 = ctx->a0 + 0x0`     (region3 phys)
- `ctx->b8 = ctx->a8 + 0x1000`  (region3 + 4 KB — second half of msg/scratch)
- `ctx->c8 = ctx->a0 + 0x1000`

Region 3 (16 KB) is split into 4 KB blocks: first 4 KB for one purpose
(probably IB ring header), second 4 KB+ for another (probably message
mailbox). Need to wire the same way in our amdgpu BO layout.

### ✅ Q5 — UVD IRQ handler is a one-liner

```c
void uvd_irq_handler(long ctx) {
    sleep_wakeup(global_event_obj, ctx + 0x50);  // wake threads sleeping on ctx->fw_base
}
```

Maps cleanly to Linux: register an IRQ source via `amdgpu_irq_add_id`,
service it with a `wake_up()` on the UVD wait queue. No custom logic.

---

## Recommended next moves

### Path A — minimum-viable port (this week)

1. **Extract the 314 KB UVD firmware** from `orbis-12.02.elf` rodata
   at `0xc8c67ff0`. Drop in `firmware/ps4/uvd-baikal-1.101.42.bin`.
2. **Replace `uvd_v4_2_start`** in our kernel with a faithful port
   of `uvd_vcpu_start_baikal`. Same MMIO sequence, same delays,
   same poll bits.
3. **Hardcode** `chip_rev=1` (Baikal) and figure out
   `per_chip_param` empirically (try `0xf`, `0x4`, `0x8` since the
   field is masked to nibble; one will work or fail visibly).
4. **GART layout**: allocate the 3 regions with the same sizes/aligns
   from amdgpu's GART, but adapted to Linux's BO model (one BO of
   `0x308000` bytes split into 3 sections, or 3 separate BOs).
5. **Boot, observe** `0x3daf` bit 1 + `0x3d67 & 0xf == 0xf`.
   If yes — we have hardware UVD on Linux PS4. If no — dig more.

Estimated cost: 2-3 days of patch work + a few iterations to dial in
`per_chip_param` and confirm GART layout.

### Path B — finish characterizing first (high confidence patch)

Decompile the 5 open questions above before writing the port. Costs
another few hours of Ghidra dig but eliminates one source of guesswork.

### Path C — verify by doing nothing first

Just extract the firmware blob and load it via mainline `uvd_v4_2`'s
existing path (skip `uvd_v4_2_start` rewrite). See if the firmware
mismatch alone was the bug. Quick check (~30 min).
**Likely insufficient** — the indirect-register Phase C is what
mainline is missing. But cheap to verify.

---

## Files to update once we patch

- `patches/6.x-baikal/0300-gpu-liverpool/0034-amdgpu-uvd-v4-2-liverpool-vcpu-start.patch`
  → **rewrite** with Sony's Baikal sequence verbatim
- `patches/6.x-baikal/0300-gpu-liverpool/0033-amdgpu-uvd-vce-liverpool-firmware-name.patch`
  → point at the new extracted blob
- `tools/orbis-kernel-dumper/wrap-uvd-firmware.py`
  → mark deprecated; replace with `extract-uvd-baikal.sh` reading
    from the kernel ELF
- `checkpoint/docs/research/sbl-port/PLAN-empirical-assume-and-try.md`
  → mark superseded — the assume-and-try test is no longer the
    critical experiment; just port Sony's start sequence
- `checkpoint/docs/research/sbl-port/2026-05-12-stealth-auth-confirmed.md`
  → still valid for *general* SBL/SMU work, but flag in header that
    UVD bring-up does not depend on it
- `checkpoint/docs/PLAN.md` → add UVD bring-up port as a near-term
  priority above the (deferred) SBL work

---

## Round 2 dig — Codex challenge follow-ups (2026-05-15 evening)

After the initial doc, ran a Codex consult that surfaced 4 risks. This
round answered them empirically.

### A. Pre-conditions concern (Codex's strongest counter)

Codex argued: "Sony's start function not doing SMU writes does not
prove Linux can start from the same hardware state — uBIOS / CAIL /
SBL may have set state we don't reproduce."

**Partial mitigation found, not a clean refutation.** Two things help:

1. The **dungeon plate comment** on `uvd_vcpu_start_gladius` explicitly
   names a concrete pre-condition gap that explains v72c's failure:
   > "Mainline writes only mmUVD_VCPU_CACHE_OFFSET/SIZE (0x3d82-0x3d87).
   > Sony ADDITIONALLY writes 0x3c68/0x3c69 with the FULL 64-bit GPU
   > base address of the firmware buffer. Without it, the VCPU starts,
   > executes its firmware preamble, attempts to read from GPU page
   > 0x300800, and the GMC has no mapping → 'VM fault read from UMC'
   > exactly as observed in our v72c-uvd test."

   This matches v72c's UART log byte-for-byte. So at least one prior
   failure has a concrete in-`start_baikal` cause — not a missing
   uBIOS pre-condition.

2. Linux amdgpu reaches `uvd_v4_2_start` only after `gmc_v7_init`,
   `dce_v8_init`, full GPU PG/CG init. The question is whether Sony's
   uBIOS does anything to UVD specifically that Linux's BIOS doesn't.

**Open risk**: SBL/uBIOS may have powered up UVD's clock domain or
trained a PHY before kernel boot. We can verify on first boot by
reading the UVD enable bits before our patch touches them. Add a
diagnostic readback of `0x1401` (SRBM_GFX_CNTL — UVD client enable),
`0x3da0` (UVD soft reset), and `0x3d40` (state machine) at the very
top of our patched start function. If those show "already enabled",
Linux inherits Sony's pre-init. If not, we know we have to do more.

### B. 3-way variant diff (Baikal / Liverpool-early / Gladius)

Decompiled all three: `uvd_vcpu_start_baikal` (c88f8610),
`uvd_vcpu_start_lvp_early` (c88fa850), `uvd_vcpu_start_gladius`
(c88fc140). Diff:

**Common to all 3 = essential UVD bring-up:**
- Phase A subset: `0x3daf |= 4`, `0x3bd4/5/3 = 0x02011002`,
  `0x3d2a` mask, `0x398` PG check, `0x3d98 |= 0x200`, `0x3d40 &= ~2`
- Phase B IH ring: `0x3d6d/6f/68 = 0`, `0x3d77 = 0x10`,
  `0x3d79/7b = 0x40c2040`, `0x3d7d = 0x88`, `0x3d68 = 0x3dff`
- IDX `0x99` packed-nibble write
- IDX `0x9b` clear bit 4
- Phase D cache regs: `0x3d82-0x3d87`
- `0x3da9 |= 0x10000000` family
- `ctx[+0x2c] = ctx[+0x24] = 0x40000000000`
- `0x1401 |= 8` (SRBM UVD client enable)
- `0x3da0` 3-stage release (`& ~4`, `& ~8`, `& ~0x2000`)
- `udelay(16000)` then poll `0x3daf bit 1` (2s timeout)
- Success path: `0x3d40 |= 2`, `0x3daf &= ~4`, snap `0x9e0`,
  `0x9e0 = (snap & ~3) + 2`

**Baikal-specific (chip_rev=1 — what we need):**
- 3 EXTRA cache regs: `0x3992/0x39c5/0x3993 = 0x02011002`
- `0x3be4` mask clear (not in LVP-early; in Gladius)
- `0x3d3c = n & 0xf` (not in LVP-early)
- IDX `0x162` write (not in LVP-early; different mask in Gladius)
- `0x3da3 = n & 0xf` (LVP-early uses `0x3da3 = ctx[+0x88]` — fw addr!)
- `0x3da1 = n & 0xf`
- `0x3c5f = 0`, `0x3c5e = 3`
- `0x3c69 / 0x3c68 = LMI_VM_VBASE` (the v72c bug — not in LVP-early)
- `0x501 = 3` (final gfx_v7 enable; not in LVP-early)

**Liverpool-early-specific (chip_rev=0 — for context, not us):**
- IDX `0x9a` written with literal 0 (not packed nibble)
- `0x3d65 &= 0xfffffff0`
- `0x3d26 = 0x80090003` then ramped through 0x70000/0x100000/0x110000
- `0x3da9 |= 0x10000000` (literal, not computed)
- `0x3dc0 = 0`
- `0x3dab |= 2` (Baikal uses `|= 1`)
- `0x3da3 = ctx[+0x88]` (firmware base!) — different semantic from Baikal

**Gladius-specific (chip_rev=2):**
- Direct `0x3d62` and `0x3d63` writes (Baikal uses IDX 0x9a/0x162 indirect path)
- `0x3bec/0x3bed/0x3bf0/0x3bf1` 3-channel context priorities
- IDX `0x162` mask `0xfff00000` (Baikal: `0xffff0000`)

**Net for Baikal patch**: copy `uvd_vcpu_start_baikal` verbatim. The
3-way diff confirms we'd be implementing Sony's exact variant for our
exact chip — no cross-variant guesses required.

### C. Q1 (per_chip_param) — n=4 confidence raised

Codex was right that "n=4 canonical" was weak as standalone. Now have
**two independent positive signals** plus one annotation:

1. **Sony source annotation** (plate comment on uvd_vcpu_start_gladius):
   > "ctx[+0x40] = clock divider hint, low 4 bits"
   This semantic name comes from Sony's debug strings cross-referenced
   with mainline AMD's clock-divider concept. Common GCN1 values: 1, 2, 4, 8.

2. **Empirical measurement** (from session 4 SBL work): we read
   `CG_SPLL_FUNC_CNTL` via the mainline `mmGCK_SMC_IND_INDEX/DATA` path
   on a live PS4 → `FB_DIV = 0x04`. The PLL was running with FB divider
   = 4 at the time of measurement. If `+0x134` mirrors that runtime
   state, n=4.

3. The IDX `0x9a` Codex-flagged precision issue: re-checked the decompile.
   Sony's `uVar1 << 0x1c` puts the FULL `per_chip_param` in bits 28-31.
   For `per_chip_param=4`: top 4 bits = 0, IDX 0x9a high nibble = 0,
   bottom nibbles = 0x44444444 pattern. **No precision loss for n=4.**
   Risk only materializes for n>15 — and the field is signed-int
   constrained (must be ≥ 0) and used everywhere as nibble, so n>15 is
   structurally implausible.

**Decision**: hardcode `n=4` as default. Add a kernel module parameter
`amdgpu.ps4_uvd_clkdiv=N` (default 4, range 0-15) so we can override
without a rebuild. UART log the chosen value at probe time.

### D. UVD stop/reset path = there isn't one

Decompiled `uvd_kmd_hw_fini` (c88f6cc0) and `FUN_c88f6e10` (the state
2→3 stop dispatch from ioctl `0x20008302`):

- `uvd_kmd_hw_fini`: pure kernel cleanup — releases IRQ vector 0x7c,
  destroys the "Uvd kmd lock" mutex, walks the device list and detaches.
  **No HW reset writes whatsoever.**
- `FUN_c88f6e10` (stop): variant-dispatched. For Baikal it calls
  `uvd_vcpu_wait_ready`. So Sony's "stop" is "wait for the firmware
  to drain" — orderly shutdown via firmware handshake, not a hardware
  reset.

**Implication for empirical iteration**: if we boot with a wrong value
of `per_chip_param` and the VCPU gets stuck mid-init, **we cannot SW-reset
it**. Only recovery paths:
- `amdgpu_device_gpu_recover()` (full GPU reset — kills GFX too)
- Kernel reload of amdgpu module (rmmod/insmod)
- Power cycle the PS4 (the PSFree gauntlet — what we already do per iter)

This matches Codex's "persistent bad state" landmine. Mitigation:
the PSFree gauntlet IS already a power cycle, so iteration safety is
free for us. But within a single boot, **don't try multiple
`per_chip_param` values** — it would only be valid if we can reset
between attempts and Sony provides no API for that.

### E. UVD firmware blob extracted, characterized

Per `uvd_kmd_hw_init_stage2`, Baikal (chip_rev=1) UVD firmware =
**314,424 bytes (`0x4ca38`) at orbis-12.02.elf vaddr `0xc8c67ff0`**.

ELF program headers (checkpoint copy at
`checkpoint/docs/research/orbis-kernel/orbis-12.02.elf`):
- LOAD segment 1: file_offset=0, vaddr=`0xffffffffc839c000`,
  size=`0xcfe758`, R+E (text+rodata). Our blob is in here.
- File offset of blob = `0xc8c67ff0 - 0xc839c000 = 0x8cbff0`

Extracted to `/tmp/uvd_baikal_1.101.42.fw`, md5 `12988c1c6d493a471c7ac99c4ad3f091`.

**First 64 bytes** (no AMD ucode-header magic — raw VCPU instruction stream):
```
00 c5 49 10 d5 49 20 e5 49 30 f5 49 00 34 00 00
dc ff 00 61 d0 ff 00 61 10 00 01 61 2f 00 04 00
dd 89 04 60 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

**Last 56 bytes** show the next firmware's banner spilling into Sony's
copy region:
```
0x4ca10:  ef be ad de  2b 5c 00 01  ...      ← end-of-blob marker (DEADBEEF + magic)
0x4ca20:  [ATI LIB=UVDFW,1.92.43]\0          ← banner of NEXT firmware
                                               (likely VCE FW v1.92.43)
```

Sony's `memcpy` literally copies 24 bytes of the next firmware's
banner. Either the VCPU ignores trailing bytes, or `0xDEADBEEF +
0x01005C2B` at offset `0x4ca10` is the VCPU-recognized "end of
microcode" sentinel after which the rest is ignored.

**For Linux**: load the raw blob into Region 1 via `request_firmware`.
No need to strip the trailing banner — Sony shipped it, so VCPU
tolerates it. No need to add an AMD ucode header (mainline `uvd_v4_2`
will skip header validation if we wire `adev->uvd.fw->size` to the
raw size and skip the header read).

Suggested location: `firmware/ps4/uvd-baikal-1.101.42.bin`.

### F. Updated risk register

| Risk | Codex's framing | Status |
|---|---|---|
| Pre-conditions Linux doesn't reproduce | strongest counter | Partial mitigation — diagnostic readback of UVD enable state at probe entry will tell us. v72c's fault is a known IN-`start_baikal` issue (LMI_VM_VBASE), not pre-condition. |
| Wrong `per_chip_param` corrupts state | "could partially work, intermittent faults" | Reduced — n=4 backed by 2 signals (Sony annotation + empirical FB_DIV). Still need first-boot readback verification. |
| `0x9a` precision (param>15) | "blind writes to poorly understood internals" | Not a risk for n=4; hardcoded mask in our port matches Sony's expression. |
| No SW reset on stuck VCPU | "persistent bad state" | Real but contained — power-cycle is part of iteration cost already. Don't try multi-attempt within a boot. |
| Firmware blob format mismatch | "validate before loading" | Verified — raw VCPU image, no header to strip/build. |

### G. Concrete patch plan (next session)

1. **Extract firmware to in-tree path** (one-time host-side):
   ```bash
   dd if=checkpoint/docs/research/orbis-kernel/orbis-12.02.elf \
      of=firmware/ps4/uvd-baikal-1.101.42.bin \
      bs=1 skip=$((0x8cbff0)) count=$((0x4ca38)) status=none
   ```
2. **Patch 0033 update**: point firmware-name to
   `ps4/uvd-baikal-1.101.42.bin`, add `MODULE_FIRMWARE` entry.
3. **Patch 0034 rewrite**: replace `uvd_v4_2_start` body with a
   chip-detection branch (read `adev->asic_type` / pdev IDs):
   - if Liverpool-2/Baikal → call new `uvd_v4_2_start_ps4_baikal()` —
     verbatim port of Sony's `uvd_vcpu_start_baikal` (Phases A-F),
     with `n` from module parameter (default 4) and `fw_va = 0x300000000`.
   - else → original mainline path (preserves Trinity/Kabini support).
4. **GART layout patch (new)**: allocate 3 BOs in the 3-region pattern
   (1.92 MB / 1.16 MB / 16 KB) and map them at UVD-VMID
   `0x300000000 / 0x3001E0000 / 0x300304000`. May need a new GART API
   call or a hand-rolled `amdgpu_gart_map_at_va`.
5. **Diagnostic readback patch**: at top of patched start function,
   read+log `0x1401`, `0x3da0`, `0x3d40`, `0x3daf` so first-boot UART
   tells us whether we inherit Sony pre-init.
6. **Module param**: `amdgpu.ps4_uvd_clkdiv=N` (default 4).
7. **Build + stage to USB** (don't reboot — wait for user signal).
8. **Test**: power-cycle, watch for `0x3daf bit 1 set` in dmesg.
   Success indicators: no "VM fault page 0x300800", no
   "uvd_v4_2_start failed", `[drm] UVD initialized successfully`.
9. **If stuck**: dump state via diagnostic readback, dial `clkdiv`,
   power-cycle, retry (cost: 1 PSFree gauntlet per attempt).

Estimated wall time: 4-6 hours patch work + 2-4 boot iterations (~30
min each on real hardware) = 1-2 sessions. Far cheaper than the prior
SBL detour.

---

## Provenance

All function decompiles and addresses captured from
`/home/meerzulee/Work/ghidra/orbis-ps4-dump` Ghidra project,
program `orbis-12.02.elf` (Sony FreeBSD kernel from 12.02 retail
PUP), via Ghidra MCP `decompile_function` calls on 2026-05-15.

Sony source path tags embedded in the kernel rodata:
- `c8bdb0e4` = `W:\Build\J02688428\sys\internal\modules\uvd\kmd\sce_gpkmd.c`
- `c8bdb1cd` = `W:\Build\J02688428\sys\internal\modules\uvd\kmd\kmd_interrupt.c`
- `c8c3039c` = `W:\Build\J02688428\sys\internal\modules\uvd\kmd\kmd_mem.c`
- `c8cb4a28` = `W:\Build\J02688428\sys\internal\modules\vce\kmd_os_wrapper.c`

These are the original Sony source files. Build identifier `J02688428`
appears in many file paths and corresponds to the 12.02 SDK build job.
