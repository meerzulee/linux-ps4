# 2026-05-12 — SBL Phase 1 (mailbox primitives + debugfs probe) — hardware result

**Patch:** `patches/6.x-baikal/0300-gpu-liverpool/0057-amdgpu-ps4-sbl-phase1-mailbox-primitives.patch`
**Config change:** `CONFIG_DEBUG_FS_ALLOW_NONE=y` → `CONFIG_DEBUG_FS_ALLOW_ALL=y` (needed to mount debugfs at all on this kernel)
**Boot logs:**
- `checkpoint/uart-logs/2026-05-12_1612-sbl-p1-mailbox-probe.log` (v1: debugfs surface invisible)
- `checkpoint/uart-logs/2026-05-12_1632-sbl-p1-debugfs-fix.log` (v2: debugfs surface present, probes run)

**Status:** ⚠️ **Phase 1 primitives mechanically work; the target address is wrong. The dungeon's "SAMU mailbox at GPU PCIe BAR offset 0x22070" assumption needs revising — we're writing into ordinary GPU register scratch space, not into a SAMU doorbell.**

---

## Open question, answered (sort of)

> Does the SAMU respond to Linux mailbox writes at all?

**Cannot tell yet — we never reached SAMU.** What we proved is that the address Sony's `samu_write(off, val)` lands at is *not* `BAR5 + off` (Linux's `adev->rmmio`).

---

## What worked

- `ps4_sbl_read_smu(adev, idx, *out)` and `ps4_sbl_write_smu(adev, idx, val)` compile and link; both surfaces in `kallsyms`.
- `/sys/kernel/debug/dri/0/ps4_sbl_smu` debugfs entry registers correctly after the config fix.
- DRM_INFO logs the configured offsets at probe time:
  ```
  ps4_sbl: Phase 1 mailbox primitives ready (rmmio=…, CMD=0x22070 ARG1=0x22074
           VAL=0x22078 STATUS=0x2207c TRIG=0x32 ACK=0x4a)
  ```
- Synchronous polling loop runs (correctly exits the moment ACK bit-0 is clear).
- The whole transaction completes in 0–2 µs — no kernel hangs, no faults.

---

## What didn't work

Four probes, increasing idx values (0, 0x1, 0xc0080000, 0xc0200000), and one write (`W 0x12345678 0xCAFEBABE`):

| Probe | `val` | `status` | `acked` | `poll_us` |
|---|---|---|---|---|
| `R 0` (first) | 0x000000bb | 0 | 1 | 2 |
| `R 0xc0080000` | 0x000000bb | 0 | 1 | 0 |
| `R 0xc0200000` | 0x000000bb | 0 | 1 | 0 |
| `R 1` | 0x000000bb | 0 | 1 | 0 |
| `R 0xdeadbeef` (after a write) | 0xcafebabe | 0 | 1 | 0 |

**Every probe gave the same response.** `val` is what was *last written* into `rmmio + 0x22078`, not anything the SAMU produced. The 0xBB on the first four reads was simply the boot-time leftover at that memory cell.

### Delta test pinning the diagnosis

Wrote `W 0x12345678 0xCAFEBABE` from debugfs, then dumped the four mailbox dwords + the trigger/ack via mainline `amdgpu_regs`:

| Byte offset | Before any probe | After `W 0x12345678 0xCAFEBABE` |
|---|---|---|
| `rmmio + 0x22070` (CMD) | 0x0000a404 | 0x0000a505 |
| `rmmio + 0x22074` (ARG1) | 0x00000001 | 0x12345678 |
| `rmmio + 0x22078` (VAL) | 0x000000bb | 0xcafebabe |
| `rmmio + 0x2207c` (STATUS) | 0x00000000 | 0x00000000 |
| `rmmio + 0x22080..0x22088` | 0xdeadbeef × 3 | 0xdeadbeef × 3 (unmapped sentinel) |
| `rmmio + 0x32` (TRIG) | 0x00010000 | 0x00010000 (bit 16 constant) |
| `rmmio + 0x4a` (ACK) | 0x00000000 | 0x00000000 (never sets) |

Conclusions:
- The values we *write* are exactly what we *read back* (bit-for-bit). It's a plain register, not a doorbell. No device is consuming our writes.
- `rmmio + 0x22080+` reads `0xdeadbeef` (canonical "unmapped/uninitialized" sentinel on this hardware).
- `rmmio + 0x32` reads `0x00010000` consistently — bit 16 is hardwired or initialised once; it does NOT change with our writes. So this isn't the trigger doorbell either.
- `rmmio + 0x4a` is always 0 — never gets set by anything. So the ack-poll loop fall-throughs instantly.

---

## What this means

The dungeon room (`orbis-dungeon/rooms/sbl-driver.md`) describes Sony's `samu_write(off, val)` as:

> reads/writes at base `(*(DAT_ca726878 + 0x10)) + offset`. The SAMU's mailbox is mmio'd into the GPU's PCIe BAR at offset 0x22070..0x2207c.

"The GPU's PCIe BAR" is **the underspecified bit**. The PS4 Liverpool exposes three BARs:

| Region | Phys base | Size | Type | Purpose (mainline conjecture) |
|---|---|---|---|---|
| 0 | 0xE0000000 | 64 MB | prefetchable, 64-bit | VRAM aperture (FB) |
| 2 | 0xE4000000 | 8 MB | prefetchable, 64-bit | Doorbells / possibly SAMU |
| 4 | I/O port 0x6000 | 256 B | I/O | Legacy I/O |
| 5 | 0xE4800000 | 256 KB | non-prefetch, 32-bit | rmmio (chip register space — what we used) |

BAR5 (rmmio) is the standard amdgpu register surface, but **256 KB is small and entirely populated by GFX/SDMA/IH/etc registers**. Byte 0x22070 of rmmio is 136 KB in — likely in the middle of an existing register bank that happens to be writable scratch (e.g. RLC scratch RAM, GFX context registers, or similar). Sony's "PCIe BAR" almost certainly means one of:

1. **BAR2** (8 MB aperture) — perfect size for a dedicated SAMU register window. PS4 customised this region — mainline amdgpu doesn't access it as "doorbells" the way later GPUs would; it could be the SAMU's own register file mapped here.
2. **A hidden physical aperture** — PS4 SoC has off-BAR peripheral mappings (the EAP/SAMU register space is sometimes mapped at fixed physical addresses, e.g. `0xfd_…` ranges that don't show up via lspci).
3. **BAR0** at a backdoor offset — some AMD APUs route register access through the VRAM aperture at low offsets; less likely on Liverpool but possible.

---

## Why the iteration was still worth it

- We now **know the primitive code path is correct** — locks, polling, ack semantics, debugfs reads/writes, scnprintf reporter, error reporting all behave. When we point them at the right address, no rework needed.
- We have a **delta-test methodology** ready: write distinctive marker, dump mainline `amdgpu_regs` at the address, see whether the write is plain-memory or device-mediated. That'll fingerprint each candidate BAR/offset quickly.
- The result **disproves** an assumption ("the BAR offsets in the dungeon doc are byte offsets in rmmio") that would have wasted a Phase 2 if we'd built async CCP / IRQ-0x98 on top of it. Catch it now, not after another 200 lines of code.

---

## Next iteration plan

Two complementary approaches, can run in either order:

### A. Empirical sweep via patched debugfs (fast, no Ghidra)

Extend `ps4_sbl.c` with two new debugfs commands:

- `P <bar> <off>` — raw read at `BAR<n> + off` (n ∈ {0,2,5})
- `I <bar> <off> <val>` — raw write at `BAR<n> + off`

Then scan candidate offsets near 0x22070 (and 0x32, 0x4a) in BAR2 and a strategic sample of BAR0. The signature of a SAMU doorbell: writing a trigger sets an ack bit that *changes when read*; the address space *reflects* writes back differently from plain memory.

Cost: ~50 lines + 1 build + 1 boot.

### B. Ghidra dig for `DAT_ca726878` initialiser

Sony's `gc/samu.c` initialises `DAT_ca726878` somewhere — probably in `samu_attach` or `samu_init`. That initialiser will reveal which BAR is being captured (via `pci_map_bar`-style or `bus_alloc_resource`-style call). Deterministic answer.

Cost: ~1–2 hours of guided RE in the existing Ghidra project.

### Resources collected by user for this dig

- amd-gfx mailing list archives — https://lists.freedesktop.org/archives/amd-gfx/
- `zamaudio/smutool` — SMU client tool (likely shows mailbox protocol shape on related AMD parts)
- AMDGPU GFX7 ISA reference — https://rocm.docs.amd.com/projects/llvm-project/en/docs-6.4.0/LLVM/llvm/html/AMDGPU/AMDGPUAsmGFX7.html
- AMD 15h family optimisation guide (PDF)
- TechPowerUp's GCN 1 architecture whitepaper (PDF)
- `fail0verflow/radeon-tools` — Liverpool-specific tooling, likely the highest-value pointer

---

## Files touched this iteration

```
config/6.x-baikal.config                                          # DEBUG_FS_ALLOW_ALL
patches/6.x-baikal/series                                         # + 0057 entry
patches/6.x-baikal/0300-gpu-liverpool/0057-amdgpu-ps4-sbl-phase1-mailbox-primitives.patch
checkpoint/docs/research/sbl-port/2026-05-12-sbl-p1-result.md     # this doc
checkpoint/uart-logs/2026-05-12_1612-sbl-p1-mailbox-probe.log     # v1 boot (debugfs missing)
checkpoint/uart-logs/2026-05-12_1632-sbl-p1-debugfs-fix.log       # v2 boot (probes run, wrong address)
```

Build artifact (current bzImage on USB): `output/6.x-baikal/bzImage` md5 `9346b84703e227c2632aeeb79fd9f7e0`.
