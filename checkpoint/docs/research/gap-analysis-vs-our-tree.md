# Investigation Results — ArabPixel + Bringup vs linux-ps4/

Wrap-up of all 6 next-step investigations. Companion to:
- `PS4_LINUX_PORTING_KB.md` — upstream survey
- `rmuxnet-bringup-analysis.md` — rmux/baikal/bringup file-by-file
- `ARABPIXEL_PAYLOADS_KB.md` — ArabPixel loader study
- `sky2-storm-fix-extracted.patch` — rmuxnet 45f6ad09 isolated PS4 quirks

Findings here OVERRIDE earlier hypotheses where they conflict.

---

## Recalibration: how far the project actually is

After reading `linux-ps4/CLAUDE.md`, `checkpoint/docs/PLAN.md`,
`checkpoint/docs/LEARNINGS.md`, the patch series and the 9000-todo notes,
this project is **much further along** than my first-pass analysis assumed.
What's already done:

- ✅ `patches/5.4-baikal/` — clean 12-patch series matching the bringup
  branch's commit topology 1:1, derived from feeRnt's 5.4.247-baikal-dfaus
  branch via `scripts/generate-5.4-patches.sh`.
- ✅ `patches/6.x-baikal/` — parallel series targeting v6.15.4, sourced from
  crashniels/linux + feeRnt fixes + a local bpcie-icc void-pointer fix.
- ✅ `patches/feeRnt-6.15.4-BaikalLove/` — 10 of feeRnt's recent BaikalLove
  commits already extracted as standalone patches.
- ✅ `patches/rmuxnet-7.0-baikal/` — 8 of rmuxnet's `ps4-baikal-7.0-port`
  commits already extracted as standalone patches.
- ✅ Custom `0002-ps4-bpcie-uart-set-port-type.patch` — user's own
  PORT_16550A fix that unblocks `console=ttySN` on 5.4 (not in any
  upstream).
- ✅ Working 5.4 build pipeline (Clang 22 + own kernel + mt76 `=y`),
  validated booting KDE/WiFi/SSH on real Baikal hardware.
- ✅ ArabPixel v24b loader in active use; Jaguar v2-ISA constraint
  documented; deeWaardt rootfs in use.
- ✅ Empirically validated `BPCIE BAR2 = 0xC8800000`,
  `UART0 = 0xC890E000`, `UART1 = 0xC890F000`.

So the "diff bringup vs linux-ps4/" task is best read as **gap-finding**
rather than wholesale comparison. The structural alignment is already
done.

---

## Investigation #1 — Diff `baikal-bringup` vs `linux-ps4/` (gap-finding)

**Method:** match each bringup commit against the corresponding
`patches/5.4-baikal/` directory.

| Bringup commit | `linux-ps4/` location | State |
|---|---|---|
| `ac129a150` x86/ps4 platform | `0100-x86-platform/0001-…` | aligned (`BCPIE_BAR4_ADDR` typo preserved) |
| `9a0958895` pci/msi exposure | `1100-pci-msi/0001-…` | aligned |
| `db81e0b26` glue drivers | `0200-ps4-drivers/0001-…` | aligned |
| `9459d023e` ICC | bundled into `0001-…` | aligned (`resetUsbPort` enabled on Baikal) |
| `e03795565` amdgpu Baikal | `0300-gpu-liverpool/0001-…` | aligned |
| `38258ccab` xhci-aeolia | `0800-usb-aeolia/0001-…` | aligned |
| `c36cd67c7` ahci PS4 | `0400-storage-ahci/0001-…` | aligned (1994-line patch) |
| `62d634820` sdhci-pci | `0500-storage-sdio/0001-…` | aligned |
| `664ceddab` sky2 | `0700-network-sky2/0001-…` | aligned (Baikal GBE commented out) |
| `445eda01e` PCI/hwmon/iommu IDs | `0900` + `1000` + `1100` | aligned |
| `c6c073cd8` pwrbutton+UART | bundled into `0200/0001-…` | aligned |
| `cfec5c7cc` x86/mfd misc | `1200-misc/0001-…` | aligned |
| (none) | `0600-wifi-mt7668/0001-…` | **extra** in our tree (vendor MT7668) |
| (none) | `0200-ps4-drivers/0002-…` UART PORT_16550A | **extra** in our tree (custom fix) |

**Verdict:** `linux-ps4/` is functionally equivalent to the bringup
branch on the 5.4 line, plus our custom UART fix and the MT7668 vendor
driver. **No bulk migration is needed.**

---

## Investigation #2 — sky2 patches in `linux-ps4/`

**Findings:**
- Our `0700-network-sky2/0001-sky2-ps4-quirks.patch` (297 lines) contains
  the standard PS4 quirks: `aeolia_get_mac_address`, `SKY2_HW_USE_AEOLIA_MSI`
  flag, `disable_msi` handling, magic register-write sequence, PHY-reset
  skip, 31-bit DMA mask, L2 switch PHY addr override.
- Baikal GBE PCI ID is **commented out** (matches bringup, intentional).
- **NOT present**: rmuxnet's `45f6ad09` interrupt-storm + memory-leak fix
  from `rmux/sky2/experimental-fixes`.

**The fix** was extracted to `patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate`
(against the bringup branch as a clean baseline). It adds:
- `AEOLIA_SP_ICR = 0x0068` register constant in sky2.h
- Explicit ICR mask before reading `B0_Y2_SP_ISRC2` in `sky2_intr`
- Explicit ICR re-arm after `napi_complete_done` in `sky2_poll`
- Same in `sky2_test_msi`
- Vendor check broadened from "Aeolia GBE only" to "any Sony GBE"
  (covers Baikal/Belize)
- `SKY2_HW_USE_AEOLIA_MSI` → `SKY2_HW_USE_PS4_MSI` (cosmetic)
- Baikal GBE PCI ID **enabled**

**Diagnosis match.** PLAN.md says "Ethernet over Baikal sky2 — broken;
LAN doesn't bring up usable interface." The storm fix root cause exactly
matches the symptom — a sky2 IRQ storm during link-up would prevent the
interface coming up cleanly. **High-priority cherry-pick.**

→ Suggested action: review the extracted patch, then turn into a real
unified diff against `0700-network-sky2/0001-…` and append as
`0700-network-sky2/0002-sky2-ps4-interrupt-storm-fix.patch`. Test on
5.4 first (low risk), then 6.x.

---

## Investigation #3 — `resetUsbPort` / `resetBtWlan`

**Findings:**
- Our `0200-ps4-drivers/0001-…` (line 2515-2516, Baikal section): both
  `resetBtWlan()` and `resetUsbPort()` are **called**.
- Aeolia section (line 1189-1190): `resetBtWlan()` called,
  `resetUsbPort()` is `//	resetUsbPort();` commented out — intentional
  (matches bringup; Aeolia hardware doesn't need the explicit USB reset).

**Verdict:** The smoking-gun ICC initialization is already present in
our tree. ✅ No action needed.

The "USB working motherfuckers" label on rmuxnet's 7.0 port commit
likely refers to additional fixes around xhci-aeolia setup ordering and
SATA PHY init (the patch bundle in `patches/rmuxnet-7.0-baikal/`), not
to `resetUsbPort` itself.

---

## Investigation #4 — EMC timer 0xc9000000 validation

**Findings:**
- `BPCIE_BAR4_ADDR = 0xc9000000` in `arch/x86/include/asm/ps4.h`
  (preserved as `BCPIE_BAR4_ADDR` typo).
- `EMC_TIMER_BASE = BPCIE_BAR4_ADDR + 0x9000 = 0xC9009000`.
- ArabPixel loader `BAIKAL_UART_BASE = 0xC890E000`. Kernel
  `BPCIE_RGN_UART_BASE = 0x10E000`. Therefore Baikal BAR2 base =
  `0xC890E000 - 0x10E000 = 0xC8800000`. PLAN.md confirms this empirically.
- BAR4 should sit immediately above BAR2 (8 MB region typical),
  putting it at `0xC9000000` — consistent with the kernel's hardcoded
  constant.

**But** the EMC timer itself is at BAR4+0x9000. The kernel comment
labels it "Baikal WDT" with uncertainty — i.e., the calibration source
might be a watchdog timer rather than a true HPET. Both can tick at
32.768 kHz, so calibration math works either way; but if the watchdog
fires during the calibration window (~1 second), TSC freq comes back
nonsense → fallback to `PS4_DEFAULT_TSC_FREQ = 1.594 GHz`.

**Verdict:** the address layout is validated. The semantic identity of
the calibration timer remains uncertain but isn't blocking — fallback
covers wrong-frequency case.

→ Suggested action: add a `pr_info` next to `ps4_calibrate_tsc` to log
the measured frequency and whether it fell back. Cheap, gives us
diagnostic data on whether 6.x calibration is plausible.

---

## Investigation #5 — Plan A/B/C recommendation

Original three plans:
- **A: adopt rmux/baikal/bringup as our 5.4 base** — Outright migration.
- **B: cherry-pick** specific patches from upstream branches.
- **C: study only** — keep using bringup as reference, no merges.

**Final recommendation: Plan B**, with three concrete cherry-picks:

### Pick 1 — sky2 storm fix (`45f6ad09`-derived) ★★★★

- File: `patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate`
- Suspected fix for: "Ethernet over Baikal sky2 — broken; LAN doesn't
  bring up usable interface" (PLAN.md row).
- Risk: Low. Standard IRQ-handler hardening. Doesn't change PCI IDs we
  already match.
- Effort: ~1 hour to convert to proper unified diff against our tree,
  ~5 min to rebuild, one PS4 reboot to test.

### Pick 2 — Wire `stop_hpet_timers(sc)` into bpcie probe ★★★

- Source: helper exists in `drivers/ps4/baikal.h:451` already, but the
  call site at line 2102 of our patch is **commented out**:
  ```
  //stop_hpet_timers(sc);
  ```
- The ArabPixel loader stops HPET on Aeolia/Belize but NOT on Baikal.
  So Baikal Linux inherits running Orbis HPET timers that may fire on
  stale memory addresses → silent fbcon hang fits this profile exactly.
- Suspected fix for: 6.x silent hang at fbcon takeover.
- Risk: Medium. `stop_hpet_timers` ends with `cpu_stop()` which
  spin-loops with cli/hlt — that would freeze a CPU. Need to read the
  helper and probably write a non-suiciding variant.
- Effort: read helper, make a "stop without halting" variant, wire up
  in `bpcie_probe` after `bpcie_glue_init()`, before `bpcie_uart_init()`.
  ~2 hours.

### Pick 3 — Pass `sb_id` from loader through boot_params ★★

- ArabPixel encodes `(sb_family<<28)|(fw_ver<<16)|(vram_mb)` in the
  kexec_load argument but doesn't forward it to the kernel.
- Currently the kernel re-detects southbridge via PCI ID. Works but
  costs early-boot time and complicates the apcie/bpcie status
  bidirectional delegation logic.
- Adding a hook would require both kernel-side and loader-side changes,
  so it's a coordinated effort — file an upstream PR rather than carry
  locally.
- Risk: Low if done as additive (existing PCI detection still works as
  fallback).
- Effort: Most useful as upstream contribution rather than local fix.

### Skipped picks

- Plan A (full migration): no value — our tree is already equivalent.
- The bringup tree's per-function multi-vector MSI domain code is
  largely **dead code** on real Baikal hardware (see new finding F3
  in the ArabPixel KB §2). Don't chase 6.x MSI bugs in the multi-domain
  paths; the production code path runs the **`arg->msi_hwirq |= 0x1F`
  single-vector aliased branch**.

---

## Investigation #6 — Deferred bringup files

Reading `ps4-apcie-icc.c`, `drivers/ata/ahci.c` PS4 sections, etc. is
**no longer high-leverage** given the project's current state. Our tree
already mirrors the bringup commits, so the open questions live in
*divergent* territory (rmuxnet 7.0 port branch, feeRnt BaikalLove
branch) — both already extracted as standalone patch sets in
`patches/rmuxnet-7.0-baikal/` and `patches/feeRnt-6.15.4-BaikalLove/`.

→ Suggested next reads (when needed):
- `patches/rmuxnet-7.0-baikal/f6cf0e0d-ps4-baikal-usb-working-motherfuckers.patch`
  — the famous USB fix.
- `patches/rmuxnet-7.0-baikal/d5e2c79b-iommu-amd-fix-ps4-baikal-coherent-dma.patch`
  — 6.x IOMMU coherent DMA fix.
- `patches/feeRnt-6.15.4-BaikalLove/040d4287-ps4-bpcie-one-msi-domain-per-function.patch`
  — MSI rework on 6.15. **But** F3 finding suggests this rework targets
  a code path that doesn't run on real Baikal hardware (since IOMMU is
  disabled by the loader). Read with skepticism.

---

## New findings (vs my earlier BRINGUP_ANALYSIS.md)

These come from cross-referencing ArabPixel's loader source with the
kernel and matter for prioritization.

### NF1 — Real Baikal MSI path is the "no-IOMMU" branch

The ArabPixel loader **unconditionally disables IOMMU** before kexec
on Baikal (`linux_boot.c:351`: `*(0xfc000018) &= ~1`). Therefore in
the bpcie driver:

```c
// ps4-bpcie.c
parent = irq_remapping_get_ir_irq_domain(&info);
if (parent == NULL) {
    parent = x86_vector_domain;
    // MSI_FLAG_MULTI_PCI_MSI is NEVER set on real Baikal
}
```

→ The single-vector aliased path (`arg->msi_hwirq |= 0x1F`,
`nvec = 1`) is the **production code path on every Baikal boot**.
Per-function multi-vector domain code is dead.

→ When debugging 6.x Baikal MSI issues, focus on:
- `bpcie_handle_edge_irq` — the software demuxer that reads
  `BPCIE_ACK_READ` to fan a single MSI out to N child IRQs.
- The mask/unmask inline-asm logic that's currently dead code (returns
  early). On real hardware the parent vector is shared, so masking a
  single subfunc requires bit-fiddling within the parent's mask —
  exactly what the dead asm does. **If 6.x mainline becomes more
  aggressive about masking individual MSI entries, the alias scheme
  could mass-mask the parent and kill IRQ delivery for the whole
  function.**

### NF2 — Loader does not pass sb_id to kernel

Confirmed in `kexec.c` and `linux_boot.c`. The kernel's PCI scan
re-discovers southbridge type via device ID. Optimization opportunity,
not a bug.

### NF3 — `stop_hpet_timers` defined but commented out

In our 5.4 patch, the helper exists in baikal.h:451 but the call site
in bpcie probe (line ~2102 of `0001-drivers-ps4-add-aeolia-belize-baikal.patch`)
is `//stop_hpet_timers(sc);`. Combined with the loader NOT stopping
HPET on Baikal (NF1 confirmed), Linux boots with stale Orbis HPET
timers running. Possibly relevant to the 6.x silent hang.

### NF4 — Aeolia uses different MSI quiesce mechanism than Baikal

Loader does:
- Aeolia/Belize: write 0 to `0xd03c844c + i*4` for i in 0..7
- Baikal: write to ECAM `0xf80a_X_0e0` (config offset 0xe0) for each func

These are fundamentally different mechanisms — Aeolia's MSI controller
appears to be a **side-band MMIO block** in BAR4 at 0x144c, while
Baikal uses standard PCI Config Space MSI capability. This matches the
kernel-side observation: `apcie` writes to `glue_write32` at
`APCIE_REG_MSI_*` offsets in BAR4 (a custom MSI controller); `bpcie`
uses `pci_msi_*` standard helpers. Two different hardware designs,
same kernel-API surface.

---

## Summary of suggested actions, prioritized

1. **Test sky2 storm fix.** Highest signal — likely fixes "ethernet
   broken on Baikal" outright. `patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate`
   is the starting point.
2. **Try `stop_hpet_timers` wired in.** Possible 6.x silent-hang
   unblocker. Requires writing a non-self-halting variant of the helper.
3. **Add TSC freq logging.** Cheap diagnostic — understand whether
   calibration succeeds or falls back.
4. **Document NF1 (no-IOMMU MSI path) prominently.** Save time when
   debugging future 6.x MSI regressions.
5. **Skip the bringup migration.** Our tree is equivalent — investing
   in our own MT7668 + UART work is higher-leverage.

Files created in this session:
- `research/baikal-bringup/` — clone of the bringup branch (study
  reference, do not modify).
- `research/arabpixel-payloads/` — clone of ArabPixel loader source.
- `checkpoint/docs/research/upstream-survey.md` (was `research/PS4_LINUX_PORTING_KB.md`), `rmuxnet-bringup-analysis.md`,
  `ARABPIXEL_PAYLOADS_KB.md`, `INVESTIGATION_RESULTS.md` (this file).
- `patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate` — staged for review.
