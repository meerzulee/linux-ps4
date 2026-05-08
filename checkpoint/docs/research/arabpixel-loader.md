# ArabPixel/ps4-linux-payloads — Knowledge Base

Companion to `PS4_LINUX_PORTING_KB.md` and `BRINGUP_ANALYSIS.md`. Covers the
**linux-loader** payloads — the user-space bridge that runs from the PS4
exploit host and kexecs the Linux kernel.

Source: https://github.com/ArabPixel/ps4-linux-payloads
Cloned at: `research/arabpixel-payloads/` (depth 1, master @ `2469d802`).

Fork lineage: `eeply` → `ps4boot/ps4-linux-payloads` → `ArabPixel/...`.
Stars: 48. Last push 2026-04-07.

---

## 1. What the payloads are

A user-space program loaded into FreeBSD/Orbis (PS4 OS) via a kernel exploit.
Its job:

1. Detect firmware version (read SCE header of `libc.sprx`).
2. Detect southbridge family (Aeolia / Belize / Belize2 / Baikal) and PS4
   model (Fat/Slim/Pro) via PCI device ID `0x9920..0x9924`.
3. Read the user's `bzImage` + `initramfs.cpio.gz` from disk.
4. Read `vram.txt` (or use built-in default) for VRAM split.
5. Read optional `bootargs.txt` for kernel cmdline overrides.
6. Pack `(sb_family << 28) | (fw_ver << 16) | (vram_mb)` into the
   `kexec_load` syscall argument.
7. Patch the FreeBSD kernel via firmware-specific offsets to install a
   custom `sys_kexec` syscall (153).
8. Jump into kernel context, run cleanup (HPET stop, GPU softreset, MSI
   disable, IOMMU disable), and **kexec** to Linux with `boot_params.hdr.hardware_subarch = X86_SUBARCH_PS4`.

---

## 2. Critical findings for our kernel work

These observations come from reading the loader source and **directly affect**
how to interpret the bringup branch's behavior.

### F1 — Baikal UART confirms BAR2 base address

`uart.c` hard-codes `BAIKAL_UART_BASE = 0xC890E000`.

The kernel's `BPCIE_RGN_UART_BASE = 0x10E000` (offset within BAR2).
Therefore Baikal BAR2 physical base = `0xC890E000 - 0x10E000 = 0xC8800000`.

This is **8 MB below** `BPCIE_BAR4_ADDR = 0xc9000000` in the kernel.

→ **Validates assumption #1** from `BRINGUP_ANALYSIS.md`: Baikal southbridge
BARs are at fixed physical addresses (`BAR2 = 0xC8800000`, `BAR4 = 0xC9000000`).
The hardcoded `EMC_TIMER_BASE = BPCIE_BAR4_ADDR + 0x9000 = 0xC9009000` is real
hardware. ✅

### F2 — The loader pre-disables MSI on every Baikal function

```c
// linux_boot.c:357-367
if (sb_id == SB_BAIKAL) {
    disableMSI(0xf80a00e0); // func 0 ACPI
    disableMSI(0xf80a10e0); // func 1 GBE
    disableMSI(0xf80a20e0); // func 2 SATA AHCI
    disableMSI(0xf80a30e0); // func 3 SDHCI
    disableMSI(0xf80a40e0); // func 4 PCIE/glue
    disableMSI(0xf80a50e0); // func 5 DMAC
    disableMSI(0xf80a60e0); // func 6 MEM/SPM
    disableMSI(0xf80a70e0); // func 7 USB 3.0 xHCI
}
```

ECAM decode of `0xf80a_X_0e0`: bus 0, slot 0x14 = **20** (matches the
kernel's `AEOLIA_SLOT_NUM = 20`), function X, config offset `0xe0`
(MSI Capability Control register).

→ **Validates the slot-20 assumption** in `pci/probe.c`. ✅
→ **Confirms 8-function topology** is identical to Aeolia (matches
`baikal.h::baikal_func_id` enum order). ✅
→ Linux receives a **clean MSI state** on entry — no carry-over from Orbis.

### F3 — Baikal runs WITHOUT IOMMU

```c
// linux_boot.c:351
*(volatile u64 *)PA_TO_DM(0xfc000018) &= ~1;  // Disable IOMMU
```

The loader unconditionally clears the IOMMU enable bit before kexec. So the
kernel boots on Baikal with **no IOMMU and no IR (interrupt remapping)**.

→ This means the kernel's `irq_remapping_get_ir_irq_domain()` returns NULL
on Baikal, `MSI_FLAG_MULTI_PCI_MSI` is **never set**, and the bpcie code
falls into the **`nvec=1` aliased single-vector path**:

```c
// ps4-bpcie.c:326-329 — production code path on Baikal
if (!(bpcie_msi_domain_info.flags & MSI_FLAG_MULTI_PCI_MSI)) {
    arg->msi_hwirq |= 0x1F;     // alias all 32 subfuncs to single MSI
}
```

→ **Major correction to BRINGUP_ANALYSIS.md §1 Layer A:** the per-function
multi-vector domains are **dead code on real Baikal hardware**. What
actually runs:

```
Each PCI function gets ONE MSI vector.
bpcie_handle_edge_irq fires → reads BPCIE_ACK_READ → demuxes to one of
N child IRQs with subfunc index 0..31.
```

This is a **hardware demuxer** architecture: 8 vectors total, software
demux to ~50 subfuncs. The inline-asm mask/unmask logic is essential
(masks individual subfuncs within a shared parent vector) but is currently
dead code (`return` early). The bringup uses `pci_msi_mask_irq` /
`pci_msi_unmask_irq` instead, which mask the **parent** vector. **This means
masking one subfunc masks ALL subfuncs of that function.**

→ **New hypothesis for the 6.x regression:** if mainline 6.x changed
mask/unmask semantics (e.g., became more aggressive about masking
individual entries), it could trigger spurious mass-masking on Baikal,
killing IRQ delivery. Worth investigating.

### F4 — The kernel's hardware_subarch dispatch is correct

```c
// linux_boot.c:340
shdr->hardware_subarch = X86_SUBARCH_PS4;
```

The loader writes 4 to `boot_params.hdr.hardware_subarch`. Kernel reads it
in `head64.c` and dispatches to `x86_ps4_early_setup()`. This handoff is
verified end-to-end. ✅

→ **`X86_SUBARCH_PS4` is the only ABI between loader and kernel for
platform identification.** No PCI scan needed for the early-setup hook.

### F5 — sb_id is NOT passed to the kernel

The loader knows the southbridge family but only uses it internally
(UART base, MSI/HPET disable choice). It does **not** stash `sb_id` in
`boot_params` for the kernel.

→ The kernel re-detects southbridge type via PCI device ID matching
(`apcie_pci_tbl` includes Aeolia + Belize, `bpcie_pci_tbl` is Baikal-only).
This is fine but redundant. Future work could use unused `boot_params`
bytes (e.g., the reserved-2 in setup_header) for fast-path detection.

### F6 — The loader stops HPET on Aeolia/Belize but NOT on Baikal

```c
// linux_boot.c:374-379  (Aeolia/Belize branch)
*(volatile u64 *)PA_TO_DM(0xd0382010) = 0;  // HPET disable
*(volatile u64 *)PA_TO_DM(0xd0382100) = 0;  // timer 0
*(volatile u64 *)PA_TO_DM(0xd0382120) = 0;  // timer 1
*(volatile u64 *)PA_TO_DM(0xd0382140) = 0;  // timer 2
*(volatile u64 *)PA_TO_DM(0xd0382160) = 0;  // timer 3
```

Baikal branch does **not** stop HPET. But `baikal.h` has a `stop_hpet_timers()`
inline that the kernel can call (if anyone wires it up — currently no
caller in the bringup tree). Baikal's HPET base is at
`BAR2 + 0x109000 = 0xC8909000`.

→ Possibly explains some odd timer behavior on Baikal. The kernel inherits
running HPET timers from Orbis. Worth wiring `stop_hpet_timers(sc)` early
in bpcie probe.

### F7 — GPU softreset is performed pre-kexec

The loader explicitly halts GFX/CP/RLC/SDMA/MEC and resets GRBM before
handing off:
- `0xe48086d8 = 0x15000000` — Halt CP blocks
- `0xe4808234 = 0x50000000` — Halt MEC
- `0xe480d048 = 1`         — Halt SDMA0
- `0xe480d848 = 1`         — Halt SDMA1
- `0xe480c300 = 0`         — Halt RLC
- `0xe4808020 |= 0x30005`  — Softreset GFX/CP/RLC
- `0xe4800e60 |= 0x00100140` — Softreset SDMA/GRBM

Then HD audio pin-config defaults are written. Kernel inherits a quiesced GPU.

→ The kernel's amdgpu init expects this clean state. Patches in
`drm/amdgpu` (commits e03795565, drm/amdgpu PS4 sections in 7.0-port)
handle the rest of the bringup. The "MEC2 microcode init" commit on
rmuxnet's recent 7.0 work is exactly the path that picks up after this
loader-side halt.

### F8 — VRAM is configurable per-boot

`vram.txt` overrides the per-payload default. Range 32 MB → 4 GB. Default 1
GB. **Sub-1GB payloads** (32/64/128/256/512 MB) target headless server
deployments — that VRAM gets returned to the system pool. The kernel doesn't
need to care; the loader sets up GPU memory regions before kexec.

→ **Implication for our kernel:** a 32-MB-VRAM boot leaves ~7.7 GB system
RAM (PS4 has 8 GB unified). Linux can use most of that as plain DRAM.

---

## 3. The 18 firmware offset table

The loader carries hand-crafted offsets for every supported FW. Stored in
`main-aio.c::fw_table[]`. Each entry: `xfast_syscall`, `printf`,
`kmem_alloc`, `kernel_map`, `patch1`, `patch2`, `pstate`.

Canonical FWs (the rest are aliased): 5.05, 6.72, 7.00, 7.50, 8.00, 8.50,
9.00, 9.03, 9.60, 10.00, 10.50, 11.00, 11.02, 11.50, 12.00, 12.50, 13.00,
13.02. **18 distinct offset sets.**

Aliasing (in `fw_detect.c::normalize_fw_ver`):
```
7.01/7.02      → 7.00
7.51/7.55      → 7.50
8.01/8.03      → 8.00
8.52           → 8.50
9.04           → 9.03
9.50/9.51      → 9.60
10.01          → 10.00
10.70/10.71    → 10.50
11.52          → 11.50
12.02          → 12.00
12.52          → 12.50
13.02          → 13.02 (NOT aliased, distinct)
```

The kernel is built **once**; only the loader changes per FW. So FW
support breaks down as "does ArabPixel have offsets for it?"

---

## 4. Per-firmware kexec stub binaries

`main-aio.c` embeds 18 `kexec.bin` blobs via `.incbin` directives. Each is
the same `ps4-kexec-common/` source compiled with a different `-DPS4_X_XX`
flag. The blob exists because the loader can't link FreeBSD-specific
symbols at runtime — instead, the stub references the kernel by absolute
offset and gets invoked after `cr0.WP` is cleared and the new syscall is
installed.

Build pipeline (`linux/Makefile`):
```
SIZES_MB = 32 64 128 256 512 1024 2048 3072 4096
FIRMWARES = 505 672 700 750 800 850 900 903 960 \
            1000 1050 1100 1102 1150 1200 1250 1300 1302
```

Default `make` produces 9 payloads (one per VRAM size, all FW-agnostic).
Each is a single ELF + matching `.bin` for self-extracting hosts.

→ Number of distinct executables shipped per release = **9** (down from
~140 before v24's runtime detection refactor).

---

## 5. UART debugging cmdlines (key for our `ps4-uart/` work)

From the README:

| Southbridge | Kernel cmdline |
|---|---|
| Aeolia / Belize | `console=uart8250,mmio32,0xd0340000` |
| Baikal | `console=uart8250,mmio32,0xC890E000` |

These addresses match the loader's `AEOLIA_UART_BASE` / `BAIKAL_UART_BASE`.
The kernel's `bpcie_uart_init` registers two 8250 ports at
`pci_resource_start(pdev, 2) + 0x10E000` and `+ 0x10F000` — but those rely
on PCI BAR2 being mapped. The early-boot `console=` arg uses **MMIO direct**
addressing to start logging before PCI scan finishes.

→ **Use these in `bootargs.txt`** when testing kernel boots on real
hardware. Combined with our `ps4-uart/` setup, this gives full visibility
from `start_kernel()` onward.

→ The README warns: "if you need UART just add this to the cmdline i have
disabled .... just for now on newer Kernel it doesnt work." Suggests a
recent loader-side change defaults UART off; you have to opt-in via
cmdline.

---

## 6. Release evolution (v20 → v24b)

Reading the README + commit log:

| Tag | Date | Notable |
|---|---|---|
| v20 | 2025-12-24 | Initial ArabPixel rebase from ps4boot |
| v21 | 2025-12-31 | FW 13.0x support |
| v21.5 | 2026-02-14 | Fixes for FW up to 13.02 |
| v22 | 2026-03-23 | Sub-1GB VRAM payloads (32/64/128/256/512 MB) |
| v23 | 2026-03-28 | `/user/system/boot/` fallback path; full FW 7.xx/8.xx coverage |
| v24 | 2026-04-02 | **AIO refactor — runtime detection** of FW + southbridge |
| v24b | 2026-04-03 | 10.50 offset fixes |

**v24 is the architectural milestone.** Pre-v24 each (FW × southbridge ×
VRAM) combination was a separate payload — easily 100+ files. v24b ships
9 files total, identifies everything at runtime, and covers all hardware
variants. This is the version testers should be using.

---

## 7. Tester instructions implied by the code

For our future Baikal testing, the recommended setup is:

1. PSFree-Enhanced (or ArabPixel's hosted page) → `goldhen.bin` →
   `ps4-linux-loader-1024mb-aio.bin` (or smaller VRAM if testing server
   workloads).
2. Drop `bzImage` and `initramfs.cpio.gz` at:
   - USB stick (highest priority), OR
   - `/data/linux/boot/` via FTP, OR
   - `/user/system/boot/` (fallback)
3. Optional `bootargs.txt`:
   ```
   console=uart8250,mmio32,0xC890E000  ip=192.168.1.50::192.168.1.1:255.255.255.0:ps4:eth0:none
   ```
4. Optional `vram.txt` with a single number in MB.

---

## 8. Things to investigate / TODO

- **Loader-kernel handoff for sb_id.** The loader detects southbridge
  cleanly; the kernel re-detects via PCI scan. Worth a small patch to
  pass `sb_id` through unused `boot_params.hdr` bytes, removing the
  detection ambiguity. ArabPixel even has the bit-packing already.
- **HPET stop on Baikal.** Aeolia/Belize loader stops HPET; Baikal
  loader does not. The kernel's `stop_hpet_timers()` helper exists but
  isn't called. Probably should be wired in `bpcie_probe`.
- **Aeolia phantom MSI clear.** `*(0xd03c844c + i*4) = 0` for i in 0..7
  on Aeolia/Belize is a different mechanism than Baikal's PCI ECAM
  writes. Worth understanding why — different MSI controller layout?
- **What is `0xfc000018`?** The "disable IOMMU" register. Check if this
  matches an AMD IOMMU MMIO address. If yes, we know exactly which
  IOMMU register the kernel should validate is cleared.

---

## 9. Quick reference — physical addresses

From combining the loader source and kernel headers:

| Region | Aeolia | Belize | Baikal |
|---|---|---|---|
| Southbridge slot | bus 0, slot 20 | bus 0, slot 20 | bus 0, slot 20 |
| Glue regs base (BAR4 / BAR2) | `0xd0200000` | `0xd0200000`(?) | `0xC9000000` (BAR4) / `0xC8800000` (BAR2) |
| UART base | `0xd0340000` | `0xd0340000` | `0xC890E000` |
| HPET | `0xd0382000` | (same) | `0xC8909000` |
| IOMMU control | `0xfc000018` | (same) | (same) |
| Aeolia MSI clear | `0xd03c844c+(i*4)` ×8 | (same) | (different — ECAM `0xf80aX0e0`) |

Aeolia BAR4 inferred as `0xd0340000 - 0x140000 = 0xd0200000` from
APCIE_RGN_UART_BASE = 0x140000.

GPU MMIO: `0xe4800000`-ish (CP/SDMA/RLC/MEC/HD-audio registers).

---

## 10. Quick-reference URLs

- Repo: https://github.com/ArabPixel/ps4-linux-payloads
- v24b release: https://github.com/ArabPixel/ps4-linux-payloads/releases/tag/v24b
- Parent fork: https://github.com/ps4boot/ps4-linux-payloads
- Linux setup tutorial: https://dionkill.github.io/ps4-linux-tutorial/
- PSFree-Enhanced (browser exploit host): https://arabpixel.github.io/PSFree-Enhanced
- `ps4-kexec-common` lineage: shuffle2 + marcan, BSD-2 license.
