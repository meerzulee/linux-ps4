# PS4 binary index — table of contents for all RE work

**Source root**: `/home/meerzulee/Downloads/PS4/` (NOT in repo, ~9 GB)
**Purpose**: catalog every binary, identify what's strategically valuable, track
which are imported into Ghidra, capture key anchors per binary.

**Iteration owner**: this doc is built by a `/loop` autonomous task. Any binary
listed below WITHOUT a "Ghidra" line is fair game to import next time the loop
fires. If you want to redirect priorities, edit the **Active priorities**
section directly — the loop reads it before picking the next target.

---

## 1. Subsystem map

| Subsystem | Variants | What it is |
|---|---|---|
| **Kernel** | Retail / Devkit / Beta / Testkit | FreeBSD kernel ELF — the OS UVD/SBL/SAMU/sceKernel code lives here |
| **Full Kernel** | Retail / Devkit / Beta / Testkit | Combined uBIOS + FreeBSD kernel image (what flashes to NAND) |
| **AMD uBIOS** | Retail / Devkit / Beta / Testkit | Pre-OS x86 boot firmware. Initializes GPU, SMU, ATOM tables. Runs BEFORE FreeBSD |
| **EAP KBL** | Retail / Devkit / Beta / Testkit × Aeolia / Belize / Belize 2 / Baikal | Embedded Application Processor Key Boot Loader. ARM. Per-SoC-family. Decrypts/validates EAP runtime |
| **EAP Kernel** | Retail / Devkit / Beta / Testkit (no SoC split) | EAP runtime kernel. ARM. Handles ICC commands, system mgmt, PSN keep-alive |
| **EMC IPL** | Retail / Devkit / Beta / Testkit × Aeolia / Belize / Belize 2 (NO Baikal) | Embedded Microcontroller Initial Program Loader. Per-SoC. Power management firmware. Note: no Baikal-specific EMC — Baikal SKUs use Belize 2 EMC |
| **PUP** | System / Recovery / Beta | PS4 firmware update files. Contain everything compressed+encrypted |
| **Filesystem** | Retail / Devkit / Beta / Testkit | Decrypted Sony userspace SELF/PRX (libSceVideoOut, libSceAvPlayer, etc.). 7z archives ~1.1 GB each |

## 2. Per-version coverage matrix

Pulled by file count, not by content inspection:

| Variant | Kernel | Full Kernel | AMD uBIOS | EAP KBL (4×SoC) | EAP Kernel | EMC IPL (3×SoC) |
|---|---|---|---|---|---|---|
| Retail | 93 | 93 | 93 | 283 | 93 | 235 |
| Devkit | 77 | 77 | 77 | 194 | 77 | 169 |
| Beta | 37 | 37 | 37 | 139 | 37 | 107 |
| Testkit | 82 | 82 | 82 | 214 | 82 | 185 |

All complete (`.elf` / `.bin`). No `.part` files in the SUB-firmware tree.

**Filesystem**: only `1202.7z` is COMPLETE (1167 MB). Other versions
(1200, 1250, 1302, 1304, 1350) are `.part` (incomplete download).

**PUP**: only `PS4UPDATE_1202.PUP` is COMPLETE in System (503 MB) and Recovery
(1083 MB). 10 other PUP files are `.part`.

**=> 12.02 (= `1202` retail / `12_020_011` devkit) is the most complete
dataset.** That's also our test target. Index prioritizes 12.02 accordingly.

## 3. Strategic value tier

For PS4 Linux RE (UVD bring-up, ethernet TX, future features):

### Tier 1 — must-have for UVD/ethernet RE (12.02)
- Kernel/Retail/1202.elf — FreeBSD kernel, contains UVD KMD, SBL, gbase
- Full Kernel/Retail/1202.elf — combined uBIOS+kernel
- AMD uBIOS/Retail/1202.elf — pre-OS GPU init, SMU/ATOM
- EAP KBL/Retail/Baikal/1202.elf — Baikal-specific EAP boot loader
- EAP Kernel/Retail/1202.elf — runtime EAP kernel (ICC handlers)
- Filesystem/Retail/1202.7z — userspace SELFs (libSceVideoOut, libSceAvPlayer)
- PUP/System/PS4UPDATE_1202.PUP — full update package

### Tier 2 — high value for cross-checking
- Kernel/Devkit/12_020_011.elf — devkit kernel has more debug symbols
- Full Kernel/Devkit/12_020_011.elf
- AMD uBIOS/Devkit/12_020_011.elf
- EAP KBL/Devkit/Baikal/12_020_011.elf
- EAP Kernel/Devkit/12_020_011.elf
- EMC IPL/Retail/Belize 2/1202.bin — closest EMC match for Baikal SKU

### Tier 3 — comparison reference (later)
- Kernel/Testkit/12_020_011.elf — third symbol set
- Other firmware versions (e.g., 11.00, 10.50) — for comparing register
  defaults / behavior changes across versions

### Tier 4 — not relevant for current goals
- VR MUP files (PSVR firmware)
- Disc Drive firmware (Blu-ray controller)
- Beta-only versions

---

## 4. Active priorities (loop reads this)

The autonomous indexing loop picks the next binary to import + analyze
from this list. Edit it freely to redirect.

### Currently waiting to be imported + analyzed (loop pickable)
*(Empty as of iteration 2 — all loop-pickable Tier 1+2 items either imported
or blocked on user-installed tooling. Blocked items below.)*

### Blocked — needs user to install tooling
1. **Filesystem/Retail/1202.7z** — needs `7z` (`sudo pacman -S p7zip`).
   Then extract, then import the UVD/AvPlayer/VideoOut SELF/PRXs.
2. **PUP/System/PS4UPDATE_1202.PUP** + **PUP/Recovery/PS4UPDATE_1202.PUP** —
   needs `pup_unpack` (e.g. https://github.com/idc/ps4-pup-unpack) or similar.
   Then split into components.

### Already imported + indexed (see Section 5)
- Kernel/Retail/1202.elf
- Kernel/Devkit/12_020_011.elf (in progress reanalyze; auto found 0 fns)
- AMD uBIOS/Retail/1202.elf
- AMD uBIOS/Devkit/12_020_011.elf (auto found 0 fns; reanalyze failed —
  unusual base addr layout, may need manual fix-up)
- EAP KBL/Retail/Baikal/1202.elf — **same md5 as Devkit/Baikal** (Sony ships
  identical KBL across Retail/Devkit for 12.02; one import covers both)
- EAP Kernel/Retail/1202.elf (small / mostly stripped)
- Full Kernel/Retail/1202.elf
- Full Kernel/Devkit/12_020_011.elf (auto found 0 fns; reanalyze in progress)
- EMC IPL/Retail/Belize 2/1202.bin — ARM Cortex, 1873 fns / 4599 syms

### Possible Tier 3 follow-ups (lower value, not active)
- EMC IPL/Retail/Aeolia/1202.bin — for SoC-comparison with Belize 2
- EMC IPL/Retail/Belize/1202.bin — same
- EAP KBL/Devkit/Belize 2/12_020_011.elf — devkit symbols for non-Baikal SoC
- EAP Kernel/Devkit/12_020_011.elf — devkit version of EAP runtime
- AMD uBIOS/Testkit/12_020_011.elf — third symbol-set for Devkit reanalysis triangulation

### Skip (intentionally deprioritized)
- All Beta variants
- All non-12.02 versions (until current UVD/ethernet goals exhausted)
- VR MUP firmware
- Disc Drive firmware

---

## 5. Per-binary anchors (filled incrementally)

Format per entry:
```
### <Subsystem>/<Variant>/<filename>
- Path: /home/meerzulee/Downloads/PS4/...
- Size: ... bytes
- MD5: ...
- Type: ELF / 7z / PUP / raw bin / etc.
- Architecture: x86_64 / ARM v7 / ARM Cortex-M / etc.
- Encrypted: yes / no
- Ghidra: imported / not imported / partial
- Function count: ... (if analyzed)
- Symbol count: ...
- Source path strings: list of `W:\Build\J*\...` paths embedded
- Banners / version IDs in rodata
- Key entry points: ...
- Notes: ...
```

### Kernel/Retail/1202.elf
- **Path**: `/home/meerzulee/Downloads/PS4/Kernel/Retail/1202.elf`
  Also at: `/home/meerzulee/Work/ps4/linux-ps4/checkpoint/docs/research/orbis-kernel/orbis-12.02.elf` (different MD5 — possibly relocated by jailbreak loader)
- **Size**: ~44 MB
- **MD5**: `cd9d798c973bf8e1f7cc83c52ce1eb5f` (Downloads copy)
- **Type**: ELF 64-bit LSB, FreeBSD, no section header (only program headers)
- **Architecture**: x86-64
- **Encrypted**: no (decrypted from PUP)
- **Ghidra**: imported as `/orbis-12.02.elf`
- **Function count**: 19,714
- **Symbol count**: 93,954
- **Base address**: `0xffffffffc839c000`
- **Key source paths in rodata**:
  - `W:\Build\J02688428\sys\internal\modules\uvd\kmd\sce_gpkmd.c` @ `c8bdb0e4`
  - `W:\Build\J02688428\sys\internal\modules\uvd\kmd\kmd_interrupt.c` @ `c8bdb1cd`
  - `W:\Build\J02688428\sys\internal\modules\uvd\kmd\kmd_mem.c` @ `c8c3039c`
  - `W:\Build\J02688428\sys\internal\modules\vce\kmd_os_wrapper.c` @ `c8cb4a28`
  - `W:\Build\J02688428\sys\internal\modules\gc\vm.c` @ `c8bab2c8`
  - `W:\Build\J02688428\sys\internal\modules\gc\cail.c` @ `c8bab2c8`
- **Banners/IDs**:
  - `[ATI LIB=UVDFW,1.101.42]` @ `c8c67f70` (followed by 314 KB raw VCPU microcode)
  - `[ATI LIB=UVDFW,1.92.43]` @ `c8cb4a80` (next firmware blob)
- **Key entry points / named functions**:
  - UVD KMD: `uvd_kmd_module_op` `c88f6270`, `uvd_kmd_hw_init` `c88f6bc0`,
    `uvd_kmd_hw_init_stage2` `c88f8cf0`, `uvd_vcpu_start_dispatch` `c88f6db0`,
    `uvd_vcpu_start_baikal` `c88f8610`, `uvd_vcpu_start_lvp_early` `c88fa850`,
    `uvd_vcpu_start_gladius` `c88fc140`, `uvd_vcpu_wait_ready` `c88f74b0`,
    `uvd_vcpu_prep_baikal` `c88f7490`, `uvd_alloc_region` `c88f94e0`,
    `get_gl_uvd_status` `c8528eb0`, `get_lvp_uvd_status` `c8762ec0`
  - SBL: `sceSblDriverInitialize` `c89b7380`, `sceSblDriverFinalize` `c89b7bf0`,
    `sceSblDriverReadSmuIx` `c89b80b0`, `sceSblDriverWriteSmuIx` `c89b81d0`,
    SAMU IRQ handler `c89b78c0`
  - GC/VM (gbase): `gbase_map` `c886a540`, `gbase_create_vmid` `c8867260`,
    `gbase_check_vm_consistency_2` `c886e560`, PTE writer `c88661c0`,
    TLB invalidate `c8866fb0`
  - CAIL: `CailGetSmcIndReg`/`CailSetSmcIndReg` (FUN_c8855a30 — clock-set dispatcher)
  - Sony's GFX clock-set (FUN_c8856160), `get_chip_family` (12 callers)
- **Notes**: this is the master target for all UVD/SBL/SAMU/ethernet RE.
  See `checkpoint/docs/research/uvd-bringup/2026-05-15-orbis-uvd-baikal-decoded.md`
  for the full UVD bring-up dig.

### Kernel/Devkit/12_020_011.elf
- **Path**: `/home/meerzulee/Downloads/PS4/Kernel/Devkit/12_020_011.elf`
- **Size**: 21,138,720 bytes
- **MD5**: `693585d1c518e615aea214bc383ad051`
- **Type**: ELF 64-bit, FreeBSD, x86_64
- **Architecture**: x86-64
- **Base address**: `0xffffffff82200000` (different from retail's `c839c000` — relocation difference)
- **Ghidra**: imported as `/devkit-12020011/12_020_011.elf`. Initial analysis
  found only 2 functions; manual `reanalyze` in progress (was at 12,945
  functions when last checked, may still be running).
- **Notes**: devkit kernel is THE source of unstripped function names that
  are FUN_xxxx in retail. Use it to label the 5 `gbase_map` callers
  (FUN_c886ddf0, FUN_c88c7b40, FUN_c8964840, FUN_c8a1e640) so we can find
  Sony's actual UVD per-VMID PT writer. **This is THE leverage binary for
  Round 8 of UVD bring-up.**

### AMD uBIOS/Retail/1202.elf
- **Path**: `/home/meerzulee/Downloads/PS4/AMD uBIOS/Retail/1202.elf`
- **MD5**: `e9d26c06abab0c56ddc90f887a9f6014`
- **Ghidra**: imported as `/ubios-retail/1202.elf`
- **Function count**: 248
- **Notes**: pre-OS GPU init. Runs BEFORE FreeBSD. May leave UVD chip state
  Sony's KMD assumes (relevant to wall #6 hypothesis B/C in UVD doc).
  Not deeply analyzed yet.

### EAP KBL/Retail/Baikal/1202.elf
- **Path**: `/home/meerzulee/Downloads/PS4/EAP KBL/Retail/Baikal/1202.elf`
- **MD5**: `df50581bb413c1ff5fe7fdbe0940f0d8`
- **Ghidra**: imported as `/eap-kbl-baikal/1202.elf`
- **Function count**: 11 (mostly stripped — encrypted KBL stage)
- **Architecture**: ARM (per the EAP family)
- **Notes**: limited usefulness in current state. Sony's KBL is signed +
  partially encrypted; what's loadable in Ghidra is mostly the wrapper.
  Compare against Devkit KBL for symbols.

### EAP Kernel/Retail/1202.elf
- **Path**: `/home/meerzulee/Downloads/PS4/EAP Kernel/Retail/1202.elf`
- **MD5**: `cfbe3a8428b33ca4b69ec550ecd1add3`
- **Ghidra**: imported as `/eap-kernel-retail/1202.elf`
- **Function count**: 11
- **Notes**: similarly mostly-stripped. The DECOMPRESSED EAP kernel
  (`eap_kernel_decompressed.bin`, 19,170 functions, 33,696 symbols) is
  the actually-useful one — already imported separately as
  `/eap-kernel-decompressed/eap_kernel_decompressed.bin`.

### Full Kernel/Retail/1202.elf
- **Path**: `/home/meerzulee/Downloads/PS4/Full Kernel/Retail/1202.elf`
- **MD5**: `b2282e0af6c41c9340e27d7954d6db94`
- **Ghidra**: imported as `/full-kernel-retail/1202.elf`
- **Notes**: combined uBIOS + FreeBSD image. Useful for cross-referencing
  when functions span the boundary. Less detailed analysis vs the split
  binaries.

### Full Kernel/Devkit/12_020_011.elf
- **Path**: `/home/meerzulee/Downloads/PS4/Full Kernel/Devkit/12_020_011.elf`
- **Size**: 22,711,704 bytes (~22 MB)
- **MD5**: `740a3382d3046ed1a988dc6abf786d80`
- **Ghidra**: imported as `/full-kernel-devkit/12_020_011.elf`
- **Architecture**: x86-64
- **Base address**: `0x00680000` (unusual — not the high-half kernel layout
  Retail uses at `0xffffffffc839c000`)
- **Function count**: 1 (auto-analyze didn't trace code paths;
  reanalyze running in background — check next iteration)
- **Notes**: same base-addr quirk as the split Devkit kernels. Likely
  needs manual base relocation or different language/loader option to
  unlock Ghidra's code-trace heuristics. Useful for symbol cross-ref
  with retail once analysis completes.

### AMD uBIOS/Devkit/12_020_011.elf
- **Path**: `/home/meerzulee/Downloads/PS4/AMD uBIOS/Devkit/12_020_011.elf`
- **Size**: 1,572,984 bytes (~1.5 MB)
- **MD5**: `ad2def9bf0820e80f05ae269fbdf92d7`
- **Ghidra**: imported as `/ubios-devkit/12_020_011.elf`
- **Base address**: `0x00680000` (same unusual layout as Devkit kernel)
- **Function count**: 1 (auto-analysis didn't trace; reanalyze FAILED).
  Different from Retail uBIOS (248 functions) — Retail is at different
  base addr and Ghidra's heuristics work there.
- **Notes**: BLOCKED on Ghidra's inability to handle this file's layout.
  May need user to manually fix up segments in Ghidra UI, set entry
  point, OR `import_file` with explicit base address override. For now
  the Retail uBIOS (`/ubios-retail/1202.elf`) covers any cross-ref need.

### EAP KBL/Devkit/Baikal/12_020_011.elf
- **Path**: `/home/meerzulee/Downloads/PS4/EAP KBL/Devkit/Baikal/12_020_011.elf`
- **MD5**: `df50581bb413c1ff5fe7fdbe0940f0d8`
- **Ghidra**: NOT separately imported — **same md5 as Retail Baikal KBL**
  (`/eap-kbl-baikal/1202.elf`). Sony ships identical KBL binary across
  Retail/Devkit for 12.02 Baikal. The Retail import covers both. If you
  need a separate Devkit-tagged view, re-import; otherwise skip.

### EMC IPL/Retail/Belize 2/1202.bin
- **Path**: `/home/meerzulee/Downloads/PS4/EMC IPL/Retail/Belize 2/1202.bin`
- **Size**: 313,504 bytes (~313 KB)
- **MD5**: `46c7c8deb2381a9b2407bb40f785049c`
- **Ghidra**: imported as `/emc-ipl-belize2/1202.bin`
- **Architecture**: ARM Cortex-M (32-bit, LE, base `0x10000000`)
- **Function count**: 1873
- **Symbol count**: 4599
- **Type**: raw ARM binary (not ELF)
- **Encrypted**: no (decrypted dump)
- **Key strings**:
  - `EMC firmware started.` @ `100024b8`
  - `EMC ID Checkcsum Error` @ `10001e3c` / `EMC HWCTRL Checkcsum Error` @ `10001e68` / `EMC THERMAL Checkcsum Error` @ `10001e9c`
  - `<SoC-EMC MsgLog>` @ `100144c0` / `SoC->EMC QMsg:Len Err` @ `100144d4`
  - `EMC Reply ErrNo:%4hx` @ `1001454c`
  - `<EMC-SC GetTemp MsgLog>` @ `10014564` (SC = System Controller)
  - `EMC-SC Watchdog Start` @ `10028594`
  - `<history SoC-EMC>` @ `10028b34`
  - `Converted address : EMC Addr(0x%x) PCIe Addr(0x%x)` @ `1000c31c`
  - HDCP2 stuff: `AKE Init, HDCP2 Version Check Error` @ `1001bec4`
  - `scversion` (System Controller version) @ `1004a992`
- **Notes**: this is the EMC firmware that Baikal SKUs use (Sony has no
  separate Baikal EMC IPL — Baikal boards reuse Belize 2 EMC). Touches:
  thermal/temperature, watchdog, HDCP2, SoC↔EMC message queues,
  address translation (EMC vs PCIe), and SC (System Controller) protocol.
  Useful for any future thermal/power/HDCP RE work.

### PUP/System/PS4UPDATE_1202.PUP
- **Path**: `/home/meerzulee/Downloads/PS4/PUP/System/PS4UPDATE_1202.PUP`
- **Size**: 503,195,648 bytes (503 MB)
- **MD5**: `a11b05ff455d2ec577fea25c63d25ef0`
- **Type**: PS4 firmware update package (encrypted+compressed container)
- **Ghidra**: NOT imported (binary container, not directly decompilable)
- **Notes**: contains all firmware versions concatenated + crypto headers.
  To use: extract via `pup_unpack` or similar tools, then individual
  components match the per-subsystem binaries we already have.
  PRIMARY VALUE: source of truth for "what shipped together as 12.02"
  and contains the Sony cryptographic signatures (which we're not trying
  to forge).

### PUP/Recovery/PS4UPDATE_1202.PUP
- **Path**: `/home/meerzulee/Downloads/PS4/PUP/Recovery/PS4UPDATE_1202.PUP`
- **Size**: 1,083,503,104 bytes (1.08 GB)
- **MD5**: `0671734da8fb342270330549ea4d418e`
- **Notes**: recovery image variant — bootable from USB to repair PS4.
  Contains a fuller filesystem snapshot than System PUP.

### Filesystem/Retail/1202.7z
- **Path**: `/home/meerzulee/Downloads/PS4/Filesystem/Retail/1202.7z`
- **Size**: 1,167,737,792 bytes (1.17 GB)
- **MD5**: `da508e4ecc4de9f4649fd506b38f7244`
- **Type**: 7z archive of decrypted Sony userspace SELF/PRX
- **Ghidra**: NOT imported (need extraction first)
- **Notes**: contains userspace libraries. Specific files of RE interest:
  - `libSceVideoOut.sprx` — display output (calls UVD?)
  - `libSceAvPlayer.sprx` — video playback (calls UVD)
  - `libSceVideodec.sprx` — video decoder (calls UVD directly)
  - `libSceVideoCoreServer.sprx` — VCE encoder
  - `libSceLibcInternal.sprx` — runtime
  TO DO: extract, then import the UVD-related ones to verify how Sony's
  userspace initiates UVD jobs (relevant to wall #6 hypothesis H from
  UVD doc, lower priority).

### EAP Kernel decompressed (already in Ghidra, source unknown — likely from a prior dump)
- **Ghidra**: imported as `/eap-kernel-decompressed/eap_kernel_decompressed.bin`
- **Architecture**: ARM v7 LE
- **Base address**: `0xc0100000`
- **Function count**: 19,170
- **Symbol count**: 33,696
- **Total memory**: 8,541,000 bytes
- **Notes**: this is the RICH EAP target — has names like `icc_thermal_handler`,
  `icc_power_handler`, `icc_button_handler`, `_icc_config_init`,
  `eap_icc_signal_start`. Useful for finding ICC commands EAP responds to.

---

## 6. Open questions for the autonomous loop

When the loop runs, it should:
1. Pick top item from Section 4 "Currently waiting"
2. For PUP/Filesystem: extract first (use `7z x` for filesystem, dedicated
   `pup_unpack` for PUP), then import individual components
3. For ELF binaries: import via Ghidra MCP `import_file`, wait for analysis,
   capture function count + key strings + banners, write to Section 5
4. Mark item as "Done" by moving from "Currently waiting" to "Already imported"
5. Commit progress with message `index: + <subsystem>/<variant>/<file>`
6. Schedule next wake or stop if list empty

Stop conditions:
- All Tier 1 + Tier 2 imported and indexed
- Hit something requiring user interaction (e.g., Ghidra crashes, disk
  space concerns)
- User edits the Active priorities to add a "stop" marker

When the loop hits a `pup_unpack` or `7z` extraction step that takes >5
minutes, it should kick off in background and schedule a quicker wake to
check progress.
