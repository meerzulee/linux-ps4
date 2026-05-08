# `rmux/baikal/bringup` — File-by-File Analysis, Plans & Assumptions

Analyzed series: 12 PS4 patches stacked on Linus 5.4.213. Total ~13 kLOC.
Source: cloned at `research/baikal-bringup/`, branch `rmux/baikal/bringup`,
HEAD `6703f8363` (2026-05-07).

This document is the working notes from manually reading every new/changed
file. Companion to `PS4_LINUX_PORTING_KB.md` (which is the upstream survey).

---

## 0. Boot-up sequence — what actually happens

```
BIOS / linux-loader (Orbis hand-off) → kernel
   │
   ├─ head64.c sees boot_params.hardware_subarch = X86_SUBARCH_PS4 (4)
   │  → calls x86_ps4_early_setup()
   │     → x86_platform.calibrate_tsc      = ps4_calibrate_tsc  (uses EMC timer @ 0xc9000000+)
   │     → x86_platform.get/set_wallclock  = no-op  (RTC is in southbridge)
   │     → legacy_pic                      = null_legacy_pic   (no 8259)
   │     → machine_ops.emergency_restart   = icc_reboot
   │     → is_ps4 = true
   │
   ├─ start_kernel() … PCI scan
   │   pci_scan_slot() filters out phantom Sony devices outside slot 20
   │   (phantoms bleed across the bus from Aeolia mirroring)
   │
   ├─ aeolia_pcie / baikal_pcie probe (function 4 of slot 20):
   │     • map BAR0/2/4
   │     • glue_init: request mem regions, log chip rev
   │       Aeolia: BAR remap every child function via APCIE_REG_BAR_*
   │       Baikal: nothing (BARs are already real on Baikal)
   │     • create MSI irq_domain(s)
   │       Aeolia: 1 shared domain, hwirq = (func<<8)|subfunc
   │       Baikal: 8 per-function domains, hwirq = (slot<<8)|(func<<5)|subfunc
   │     • alloc N MSI vectors (Aeolia: 23, Baikal: 32)
   │     • bpcie_uart_init / apcie_uart_init: register both 8250 UARTs
   │     • bpcie_icc_init / apcie_icc_init:
   │         - map mem-func (function 6) BAR5 → SPM region
   │         - map ICC doorbell/status registers
   │         - request_irq for ICC subfunc
   │         - i2c bridge over ICC
   │         - resetBtWlan() via ICC major=5 minor=0 with 0x03  (Baikal only)
   │         - resetUsbPort() via ICC major=5 minor=0x10 with 0x01  (Baikal only)
   │         - icc_pwrbutton_init → ICC major=8 minor=1 to enable notifications
   │         - do_icc_init: sets blue LED, suppresses orange
   │         - pm_power_off = icc_shutdown
   │         - register_chrdev /dev/icc for userspace
   │     • mark apcie_initialized / bpcie_initialized = true
   │
   ├─ Other PS4 drivers probe-deferred until apcie_status() returns 1:
   │     xhci-aeolia (covers Aeolia/Belize/Baikal XHCI)
   │     ahci_init_one (called from xhci-aeolia.c on Belize/Baikal middle controller!)
   │     sdhci-pci-core sdhci_aeolia variant
   │     sky2 with PS4 quirks
   │     amdgpu with ps4_bridge.c HDMI bridge
   │
   └─ initramfs → userspace
```

---

## 1. The 12 patches, layer by layer

### Layer A — Foundation (must be applied in this order)

**`ac129a150` x86/ps4: Sony PlayStation 4 platform support**

Files: `arch/x86/Kconfig` (+8), `arch/x86/include/asm/ps4.h` (+99),
`arch/x86/include/asm/setup.h` (+6), `arch/x86/include/uapi/asm/bootparam.h`
(+1), `arch/x86/platform/Makefile` (+1), `arch/x86/platform/ps4/Makefile`,
`arch/x86/platform/ps4/calibrate.c` (+116), `arch/x86/platform/ps4/ps4.c`
(+85).

What it does:
- Defines `CONFIG_X86_PS4` and adds a new `X86_SUBARCH_PS4` boot-param subarch
  enum value (4).
- `ps4.h` declares the cross-driver ABI: `apcie_assign_irqs`,
  `apcie_free_irqs`, `apcie_status`, `apcie_icc_cmd`, plus parallel `bpcie_*`.
  All have `-ENODEV` stubs when `!CONFIG_X86_PS4`.
- `ps4.c` registers the early setup hook that swaps `x86_platform`
  function pointers and disables the legacy PIC.
- `calibrate.c` calibrates TSC against the Aeolia EMC timer at hardcoded
  physical address `0xc9000000 + 0x9000`. Falls back to
  `PS4_DEFAULT_TSC_FREQ = 1594000000` on failure.

Assumption #1 — **`BPCIE_BAR4_ADDR = 0xc9000000` is hard-coded** and assumed
to be the BAR4 physical address Sony's bootloader programs for the
southbridge. This survives only because the loader pre-configures it —
post-kernel, drivers re-discover BARs through PCI.

Assumption #2 — TSC calibration uses Aeolia EMC timer registers even on
Baikal. The header says "EMC_TIMER_BASE … BAR4 + 0x9000, seems this is not
HPET timer, Baikal WDT" — comment admits uncertainty. The Baikal HPET is
elsewhere (`BPCIE_HPET_BASE = 0x109000`). This calibration may be running
against Baikal's WDT not its HPET. **Worth verifying** before pulling
this onto Baikal-only kernels.

---

**`9a0958895` pci/msi: PS4 MSI controller routing** (4 lines added)

Files: `arch/x86/include/asm/msi.h` (+2), `arch/x86/kernel/apic/msi.c`
(`static` → `void`), `kernel/irq/msi.c` (+1).

What it does:
- Exposes `irq_msi_compose_msg` (was `static`) so the PS4 MSI controllers
  can call it directly.
- Makes `ops->msi_prepare` optional in `msi_domain_prepare_irqs()` — if a
  driver doesn't supply one, the call is skipped instead of NULL-derefing.

Both apcie and bpcie use `irq_msi_compose_msg` as their
`.irq_compose_msi_msg`. The `msi_prepare` softening lets bpcie pass an
empty stub.

Risk #3 — The `msi_prepare` change is a **kernel-wide behavior change** for
any MSI domain. Upstream may have reasoned that domains *must* have a
prepare op; making it optional could mask bugs. In 6.x this whole
plumbing changed — the `ops->msi_prepare` skip pattern is replaced by
proper opt-in via flags.

---

**`db81e0b26` drivers/ps4: Aeolia/Baikal southbridge glue drivers** (1576 lines)

Files: `drivers/Makefile` (+1), `drivers/ps4/Makefile`, `aeolia-baikal.h`,
`aeolia.h`, `baikal.h`, `ps4-apcie.c` (540), `ps4-bpcie.c` (656).

The architectural heart. Two drivers, one for each southbridge, sharing the
ICC protocol header. **They register against different PCI device IDs** —
Aeolia (`0x90a1`) and Belize (`0x90cc`) → apcie driver. Baikal (`0x90db`) →
bpcie driver. Both target the same logical slot (function 4 of devfn 20)
but they're installed simultaneously and only one matches per-system.

Key data structures:
- `struct abpcie_dev`: shared between both. Holds `pdev`, BAR maps,
  `irq_domain`, `nvec`, `serial_line[2]`, embedded `abpcie_icc_dev`.
- `struct abpcie_icc_dev`: ICC mailbox state — `spm_base`, request/reply
  headers, reply lock, wait queue, i2c adapter, power-button input dev.
- `struct icc_message_hdr`: 16-byte packed protocol header — magic, major,
  minor, unknown, cookie, length, checksum (8-bit sum).

PCI function ID layout (same for Aeolia and Baikal):
```
fn 0: ACPI    fn 1: GBE    fn 2: AHCI   fn 3: SDHCI
fn 4: PCIE    fn 5: DMAC   fn 6: MEM    fn 7: XHCI
```

Aeolia subfunc layout (per-func MSI count): `[4, 4, 4, 4, 31, 2, 2, 4]`
Baikal subfunc layout (per-func MSI count): `[2, 1, 1, 1, 31, 2, 3, 3]`

Aeolia MSI domain — **single** domain on function 4. hwirq =
`(func << 8) | subfunc`. Driver writes per-vector MSI registers in glue
BAR4 (`APCIE_REG_MSI_*`). Function 4 is special: 24 contiguous slots +
7 trailing. Sentinel subfunc `0xff` means "alias all subfuncs of this
function to one IRQ" used when no IOMMU/IR.

Baikal MSI domain — **eight** domains, one per function. hwirq =
`(slot << 8) | (func << 5) | (0..31)`. Standard pci_msi_*
mask/unmask/write_msg helpers — Baikal does the routing in hardware.
Demultiplex on the way in: `bpcie_handle_edge_irq` for funcs 4/5/7
reads back `BPCIE_ACK_READ` to find which subfunc fired, then calls
each child IRQ. **The mask/unmask functions contain dead inline-asm**
(returns immediately) — the original RE'd PS4 firmware logic, kept as
documentation/fallback.

Quirk: `apcie_assign_irqs()` delegates to `bpcie_assign_irqs()` if
`bpcie_initialized` — drivers don't need to know which southbridge they're
running on. Same for free.

Quirk: Both glue init paths force `nvec = 1` when `MSI_FLAG_MULTI_PCI_MSI`
is unset (no IOMMU/IR), aliasing all subfuncs onto a single vector.

---

**`9459d023e` drivers/ps4: ICC** (1368 lines)

Files: `drivers/ps4/icc/i2c.c` (158), `ps4-apcie-icc.c` (589),
`ps4-bpcie-icc.c` (621).

ICC = the EAP system controller mailbox. Two address regions are needed:
1. Doorbell/status registers in the southbridge BAR2 (Baikal) or BAR4 (Aeolia).
2. **Shared message buffer (SPM)** at the *MEM function's* BAR5 — get_slot
   on function 6, map BAR5 + offset.

Protocol:
- 16-byte header + payload, padded to 32-byte minimum, max 0x7f0.
- Cookie auto-incremented per request, matched on reply.
- 8-bit byte-wise checksum.
- REQUEST area at SPM+0x000, REPLY at SPM+0x800. `BUF_EMPTY/BUF_FULL`
  flag bytes at +0x7f0/+0x7f4.
- Doorbell write `BPCIE_ICC_SEND=0x01` triggers send. Status register
  bit `0x01` indicates incoming; bit `0x02` is ACK.
- `wait_event_interruptible_timeout(... ICC_TIMEOUT=15s)` — some commands
  are slow (firmware programs running on EAP).

**Boot-time ICC commands (Baikal-specific, in `bpcie_icc_init`):**
```
maj=2 min=6                          → "service start" handshake
maj=1 min=0  data=0x10               → switch service mode
maj=9 min=0x20 data=led_config       → blue solid + white off + orange off
maj=5 min=0    data=0x03             → resetBtWlan() — turn ON BT/WLAN
maj=5 min=0x11                       → query USB0 status
maj=5 min=0x10 data=0x01             → resetUsbPort() — turn ON USB
maj=8 min=1    data=0x100            → enable power button notifications
maj=8 min=1    data=0x102            → enable reset button notifications
```

**This is the smoking gun for "USB working" on the 7.0 port.**
Without `resetUsbPort()`, the Baikal USB controllers stay power-gated by
the EAP. The xHCI driver finds the PCI device, maps registers, but the
hardware is dead → boot hangs or USB-keyboard-toggles-then-dies symptom
matches exactly. feeRnt's BaikalLove branch is iterating on MSI/IRQ
because the symptom resembles routing — but a missing `resetUsbPort` would
look the same.

Power management:
- `icc_shutdown` (registered as `pm_power_off`) sends maj=4 min=1 with
  `[0,0,2,0,1,0]` then mdelays 3 sec.
- `icc_reboot` (registered as `machine_ops.emergency_restart` from ps4.c)
  sends maj=4 min=1 with `[0,1,2,0,1,0]`.
- Power button: ICC events maj=8 min=0x010/0x011 → `icc_pwrbutton_trigger`
  → input_report_key(KEY_POWER).

Userspace ABI:
- `/dev/icc` char-major `'I'` = 73 (`ICC_MAJOR`).
- One ioctl: `ICC_IOCTL_CMD` with `struct icc_cmd {major,minor,data,length,reply,reply_length}`.
- 64 KB tmp buffer pre-allocated for one in-flight command. **Single mutex,
  no concurrency** — matches Sony's "never two outstanding" assumption.

i2c shim (`drivers/ps4/icc/i2c.c`): registers a virtual i2c adapter that
proxies I/O to ICC commands. Used by amdgpu's `ps4_bridge.c` to talk to
the Panasonic MN86471A / MN864729 DP→HDMI bridge over its real i2c bus.

Risk #4 — **`icc_sc` is a global**. There's only one Baikal/Aeolia in a
PS4, but for QEMU/multi-instance testing this prevents two concurrent
ICC contexts.

Risk #5 — On the i2c command path, `apcie_icc_cmd(0x10, 0, ...)` is used
even on Baikal. Inspect — `apcie_icc_cmd` in `apcie-icc.c` should
probably also delegate to `bpcie_icc_cmd` if Baikal is up. Need to read
that file to confirm. (Not loaded in this analysis — flagged for later.)

---

### Layer B — Subsystems

**`e03795565` drm/amdgpu: PS4 Baikal graphics** (~2000 lines, 21 files)

Bulk of work in `ps4_bridge.c` (769 lines) and modifications to
`gfx_v7_0.c` (+661), `cik.c` (+318), `cik_sdma.c` (+26),
`gmc_v7_0.c` (+19), `dce_v8_0.c` (+44), `amdgpu_connectors.c` (+44).

Key insight: **PS4's GPU is Bonaire (CIK family)** — Liverpool/Gladius
ASIC IDs are added to `amd_asic_type.h` and `cik.c` gets a new ASIC table
entry. The `ps4_bridge.c` is a custom DRM bridge driver for Sony's HDMI
output path:
- The display chain is `amdgpu DP encoder → DP-to-HDMI bridge IC →
  HDMI port`.
- The bridge IC is Panasonic **MN86471A** (CUH-11xx) or **MN864729**
  (CUH-12xx and later, including Baikal).
- The bridge speaks i2c, but its i2c bus is **not on the PCIe DP-AUX
  channel** — it's hung off the southbridge ICC. So the driver builds a
  command queue (`cq_init`/`cq_writereg`/`cq_mask`/`cq_wait_set`/
  `cq_delay`) that's batched into a single ICC major=0x10 minor=0
  command, and the EAP firmware unrolls and executes it.
- Two enable sequences (one per bridge model), each ~40 register
  writes for video + ~20 for audio preinit. The MN864729 path has a
  CUH-12xx-specific magic value at 0x10c5.

The amdgpu modifications enable Bonaire support paths that mainline
disabled, set up custom GMC for the PS4's unified memory layout, and
hook the bridge via the encoder framework.

Risk #6 — **`drm_get_edid` dependency on the i2c-over-ICC adapter**.
EDID never traverses real DP-AUX. The bridge driver fetches EDID via
ICC i2c-bus reads from the bridge IC. Any 6.x change to DRM bridge
attach order can break this — the connector must come up before EDID
is queried. (oberdfr's `6.17.1-edid-oberdfr` branch tackles a related
issue: getting EDID from Orbis directly.)

---

**`38258ccab` usb: host: xhci-aeolia** (601 lines)

Files: `drivers/usb/host/Kconfig` (+7), `Makefile` (+1), `xhci-aeolia.c`
(562), `xhci-aeolia.h` (14), `xhci.c` (~31 modified), `xhci.h` (+1).

Most surprising thing here: **xhci-aeolia.c also contains the AHCI
probe**. Function 7 of the southbridge presents 3 sub-controllers via
3 BAR pairs (BAR0/1, BAR2/3, BAR4/5). On Aeolia all 3 are XHCI. On
Belize/Baikal the **middle controller (index 1) is AHCI/SATA** instead
of a third XHCI. The driver:

```c
for (idx = 0; idx < NR_DEVICES; idx++) {
    if (dev->device != PCI_DEVICE_ID_SONY_AEOLIA_XHCI && idx == 1)
        continue;                         // skip middle slot
    xhci_aeolia_probe_one(dev, idx);
}
ahci_init_one(dev);                       // separately probes AHCI
```

`ahci_init_one()` is a near-copy of `ahci/ahci.c::ahci_init_one`, with
PS4-specific bits inlined: `bpcie_sata_phy_init` (Baikal SATA PHY
initialization), DMA mask 31-bit, devm-managed allocations.

Other notes:
- `XHCI_PLAT | XHCI_PLAT_DMA` quirks: don't enable MSI in xhci core
  (we already did it), don't touch DMA mask (we set 31-bit ourselves).
- Uses `pci_alloc_irq_vectors(... PCI_IRQ_MSIX | PCI_IRQ_MSI)` — standard
  path, NOT `apcie_assign_irqs`. Per-controller IRQ from `dev->irq + index`
  if multi-vector, else shared.
- Apparently feeRnt's BaikalLove `axhci->host` NULLify fix is needed
  because if `ahci_init_one` fails, `axhci->host` is uninitialized
  garbage and the remove path OOPSes.
- `bus_master` is a *static global* gate to call `pci_set_master` once.
  Threading-unsafe but only called from probe.

Risk #7 — Coupling AHCI into xhci-aeolia is a pragmatic shortcut that
will rot. Mainline ahci has moved through ~5 years of changes that
this inlined copy doesn't track. Splitting AHCI back out into its own
driver (with PS4 PCI IDs registered separately) would be cleanest.
That's what `ata: ahci: PS4 southbridge AHCI` (commit `c36cd67c7`)
seems to attempt — let me re-check the ahci.c changes…

Actually `c36cd67c7` adds 1891 lines to ahci.c — a significant rework.
Given xhci-aeolia.c also has its own `ahci_init_one`, the actual probe
flow on Baikal might be: xhci-aeolia handles function 7 (XHCI+AHCI
combined), while function 2 of the southbridge is also probed by
ahci.c (regular SATA on the dedicated AHCI function). **Two AHCI
controllers exist on Baikal**: one at function 2 (HDD), one at the
middle of function 7 (Blu-ray drive). Issue #14 ("No blu-ray drive
Baikal slim 5.4.247") on feeRnt's repo aligns with this split.

---

**`c36cd67c7` ata: ahci: PS4 southbridge AHCI** (1891 lines, mostly to ahci.c)

Adds PS4 vendor/device IDs to the standard ahci probe table and patches
in custom MSI assignment via `apcie_assign_irqs`. Bulk size suggests
extensive PS4-specific logic in ahci.c — would need a follow-up read for
specifics. Most of this likely covers function 2 (the dedicated AHCI for
HDD), distinct from the function 7 middle slot (Blu-ray).

---

**`62d634820` mmc: sdhci-pci: PS4 SDHCI** (71 lines)

Adds `sdhci_aeolia` PCI fixes table, registers Aeolia/Belize/Baikal SDHCI
device IDs against it. Probe path:
- `aeolia_probe()`: defers if apcie not ready, fixes `chip->num_slots = 1`
  and `chip->first_bar = 0`, patches the PCI class to advertise IFDMA.
- `aeolia_probe_slot()`: alloc MSI vectors with stock helper.
- `aeolia_enable_dma()`: forces 31-bit DMA mask.

Also refactors sdhci-pci core to support `chip->first_bar` — minor
plumbing.

This SDHCI is for the **internal eMMC** which holds the embedded firmware/
boot loaders. It's distinct from the SDIO WiFi card — that one lives on
a **second SDHCI controller** (function 3 has multiple BARs / phantom).
This is what feeRnt has spent years stabilizing for the Marvell 88w8897.

---

**`664ceddab` net: sky2: PS4 Marvell Ethernet** (127 lines)

Significant PS4 quirks bolted into upstream sky2:
- New device IDs for Aeolia/Belize GBE (Baikal GBE explicitly **commented
  out** — Baikal GBE seems unsupported in this branch).
- `aeolia_get_mac_address()` — reads MAC from SPM at `BP_BASE = 0x2f000`
  on the MEM-function BAR5. PS4 stores its MAC in NVS, not in the chip.
- `sky2_reset()` PS4 quirk: writes magic registers (0x60/0x64/0x68/0x6c
  initialization, 0x158/0x160 mask clears) for Aeolia GBE.
- Skip PHY reset on Aeolia (it hangs).
- PHY address override: `hw->phy_addr = 1` for Aeolia (built-in L2 switch
  with separate PHY layout).
- 31-bit DMA mask.
- `apcie_assign_irqs(pdev, 1)` is preferred over `pci_enable_msi()` —
  this is the *only* subsystem that goes through the apcie MSI path
  rather than stock pci_alloc_irq_vectors. Marked with
  `SKY2_HW_USE_AEOLIA_MSI` flag.

Risk #8 — Baikal GBE was disabled by commenting out the device ID. There's
a separate `ps4-baikal-ethernet-experiment` branch on rmuxnet (846b0b28)
that's working on this. Until that lands, Baikal has no ethernet on
this stack. Note rmuxnet's `rmux/sky2/experimental-fixes` (`45f6ad09`)
fixes a different cross-southbridge interrupt-storm bug.

---

### Layer C — IDs, misc, config

**`445eda01e` pci: hwmon: iommu IDs and quirks** (47 lines)

- `pci_ids.h`: 24 new constants — all 8 functions × 3 southbridges. Also
  AMD `16H_M41H_F3/F4` (the PS4 APU's northbridge).
- `fam15h_power.c`, `k10temp.c`: register the M41H NB on those hwmon
  drivers so `lm-sensors` / hardware monitoring works.
- `iommu/amd_iommu_init.c`: **bypasses `check_ioapic_information()`**
  on `CONFIG_X86_PS4` (PS4 has no real IO-APIC because no legacy PIC).
  Comment marks this as a hack: "TODO this should detect ps4-ness at
  runtime."
- `pci/probe.c`: filters phantom Sony devices outside slot 20 from PCI
  enumeration. Magic constant `AEOLIA_SLOT_NUM = 20` chosen "Freebsd uses
  20 so use that too".

Risk #9 — IOMMU bypass is **build-time** gated. Any kernel built with
`CONFIG_X86_PS4=y` will skip IOAPIC validation **system-wide**. Fine for
PS4-only builds. Not fine for a generic distro-kernel that also wants
PS4 support.

---

**`c6c073cd8` drivers/ps4: power button + UART** (208 lines)

Already covered above.
- `apcie-pwrbutton.c` (74): registers `Power Button` input device with
  KEY_POWER. ICC events major=8 minor=0x010/0x011 fire it.
- `apcie-uart.c` / `bpcie-uart.c` (67 each): register **two 8250 UARTs**
  per southbridge at `BPCIE_RGN_UART_BASE` (BAR2+0x10E000 for Baikal)
  with regshift=2, uartclk=58.5 MHz, sharing the parent IRQ vector.

The `ps4-uart/` sibling project in our work tree very likely uses these
UART headers physically. The driver-level support is straightforward
once the southbridge MSI vector for `SUBFUNC_UART0/1` is wired.

---

**`cfec5c7cc` x86: kernel: mfd: misc** (10 lines)

- Adds AMD M41H northbridge IDs to `amd_nb.c` so AMD NB code recognizes
  PS4's APU.
- `head64.c`: dispatches `X86_SUBARCH_PS4 → x86_ps4_early_setup()`.
  **This is the wiring** — without this, the platform setup would never
  fire even with `CONFIG_X86_PS4=y`.
- `entry/Makefile`: drops `thunk_$(BITS).o` from the always-built objects.
  Suggests something in PS4 builds breaks the thunk path — probably LTO
  or a hand-tuned config that doesn't need it. This is **suspicious for
  upstream merging**.
- `mfd/Kconfig`: makes `MFD_CORE` default to `y`. Probably because some
  PS4 driver pulls in MFD without explicitly selecting.

Risk #10 — **`obj-y -= thunk_$(BITS).o`** is a fragile edit. Mainline
relies on those for fentry/profiling. If we want this to survive
upstream review, we need `CONFIG_X86_PS4` gating instead of an
unconditional removal.

---

**`6703f8363` defconfig** (3739 lines)

Single config file (`config`, not under arch/x86/configs/) with:
- `CONFIG_LOCALVERSION="-whitehax0r"` ← inherited from whitehax0r/ps4-linux-baikal
- `CONFIG_X86_PS4=y`
- `CONFIG_HZ=1000` (latency-friendly, not the 250 of rmuxnet's 7.0
  Server profile)
- `CONFIG_TRANSPARENT_HUGEPAGE=y`
- `CONFIG_PCI_MSI=y`, `CONFIG_AMD_IOMMU=y`, `CONFIG_IRQ_REMAP=y`
- `CONFIG_DRM_AMDGPU=y`, `CONFIG_USB_XHCI_AEOLIA=y`
- `CONFIG_PHYSICAL_START=0x1000000` / `ALIGN=0x200000` — standard.

Note `LOCALVERSION` reveals provenance: this defconfig started life on
whitehax0r's Baikal tree and was inherited up the chain DFAUS → feeRnt →
rmuxnet. The "5.4 → 5.15 regression" on Baikal could partly be config
drift, not just code drift.

---

## 2. Architecture model — pulling it together

The PS4 has **three computers** that all need to cooperate:

```
                ┌─────────────────────────────┐
                │  EAP / system controller    │
                │  (ARM, runs Sony firmware)  │
                │  - power gating             │
                │  - thermal/fan/LED          │
                │  - power button             │
                │  - SATA PHY init            │
                │  - HDMI bridge i2c          │
                │  - audio routing            │
                │  - WiFi/BT enable           │
                │  - USB enable               │
                └────────────┬────────────────┘
                             │ ICC mailbox
                             │ (doorbell + SPM shared mem)
                             │
                ┌────────────▼────────────────┐
                │  Aeolia/Belize/Baikal       │
                │  southbridge                │
                │  PCI slot 20, 8 functions:  │
                │    0:ACPI 1:GBE 2:AHCI      │
                │    3:SDHCI 4:PCIE-glue/MSI  │
                │    5:DMAC 6:MEM/SPM 7:XHCI  │
                │  Custom MSI router          │
                │  Two 8250 UARTs             │
                └────────────┬────────────────┘
                             │ PCIe
                             │
                ┌────────────▼────────────────┐
                │  AMD Jaguar APU + Bonaire   │
                │  GPU (Liverpool / Gladius)  │
                │  Linux runs here            │
                │  Custom IRQ setup (no PIC)  │
                │  Custom TSC calibration     │
                │  Custom IOMMU bypass        │
                └─────────────────────────────┘
```

The kernel cannot do anything without **first establishing ICC** — even
USB, SATA-PHY, GBE PHY init are gated on commands sent via ICC. That's
why probe order is:

```
1. apcie/bpcie probes (function 4)  [synchronous, registers MSI domain]
2. ICC comes up (in glue init)      [async, 15s timeout per cmd]
3. resetBtWlan, resetUsbPort etc.   [Baikal-only side effects]
4. All other functions probe with -EPROBE_DEFER until apcie_status() == 1
```

If ICC doesn't come up, **everything else fails**. If `resetUsbPort()` is
skipped, USB starts then dies. If MSI domains are misconfigured, IRQ
storms ensue. These are exactly the symptoms feeRnt and rmuxnet are
fighting on 6.15/7.0.

---

## 3. Why Baikal probably regresses on 6.x

Hypotheses, ranked by likelihood:

### H1 — MSI domain plumbing reworked between 5.4 and 6.x  ★★★★

The 5.4 driver uses `X86_IRQ_ALLOC_TYPE_MSI`, `init_irq_alloc_info`,
`pci_msi_domain_write_msg`, hand-rolled per-function `msi_domain_info`.
In 6.0–6.6, x86 IRQ allocation moved to `X86_IRQ_ALLOC_TYPE_PCI_MSI`
(distinct from older MSI/HPET/etc. types), and per-domain ops now
require `msi_check`/`msi_prepare` semantics tightened. feeRnt's recent
BaikalLove commits explicitly fight this: "ps4-bpcie: Adjust msi_prepare
for IRQ ALLOC_TYPE_PCI_MSI", "ps4-bpcie: Use init_irq_alloc_info at domain
creation again", "ps4-bpcie: Properly create 1 MSI domain per 14.x pci
function".

**Smoking-gun evidence:** The bringup `bpcie_msi_domain_set_desc` sets
`arg->type = X86_IRQ_ALLOC_TYPE_MSI` (line 311 of `ps4-bpcie.c`). In 6.x,
PCI MSI allocations expect `X86_IRQ_ALLOC_TYPE_PCI_MSI`. A type mismatch
silently misroutes the vector → IRQ never delivers → boot wedges before
USB.

### H2 — Missing ICC initialization commands  ★★★

The bringup `bpcie_icc_init` calls `resetBtWlan()` and `resetUsbPort()`.
If a port to 6.15 dropped these (e.g., during a refactor), USB stays
dead. This matches the "USB briefly works, then dies" symptom — actually
USB *never* fully comes up; only the DP detection / pre-USB phase
appears to (caps-lock LED works because it's HID-class polling something
that's already initialized in firmware).

### H3 — IOMMU bypass needs updating  ★★

`amd_iommu_init.c` interface changed several times in 6.x. The
`check_ioapic_information` skip at build-time isn't a stable hook —
upstream may have moved/renamed it.

### H4 — pci_scan_slot phantom-filter logic  ★

The `pci/probe.c` change uses `pci_bus_read_dev_vendor_id` with a 60ms
timeout. In 6.x the API signature changed (returns errno vs vendor in
out-param vs vendor as return). A silent miscompile or wrong
return-value check → either every PCI device skipped or no phantoms
filtered → glue probe never fires.

### H5 — Defconfig drift  ★

`HZ=1000` plus `CONFIG_TRANSPARENT_HUGEPAGE=y` plus PS4-specific kernel
flags. Some unstated config is enabling/disabling something in 6.x that
crashes early. Lower likelihood given the same defconfig works on Aeolia
boards in 6.15.

---

## 4. Plans / ideas for our local linux-ps4 5.4 tree

We're on Baikal 5.4. The bringup branch is already 5.4.213. Question:
**should we rebase onto bringup?**

### Plan A — Adopt rmux/baikal/bringup as our base (medium effort, high reward)

The bringup tree is the cleanest 5.4 Baikal stack publicly. Twelve clean
commits, well-named, no stray cleanup. Adopting it means:
- Replacing our existing 5.4-baikal patches with these 12.
- Keeping our existing config (or merging with `whitehax0r` defconfig).
- Re-running build.sh end-to-end.
- Preserving any rmux/sky2 stability fixes that aren't in this branch
  (the `sky2 experimental` is on a separate rmuxnet branch).

Risk: our checkpoint/build-log tracks our current setup. A switch
loses incremental progress.

### Plan B — Cherry-pick specific patches (low effort, partial reward)

Pull only the ones that obviously help us:
- `rmux/sky2/experimental-fixes 45f6ad09` — addresses sky2 storms across
  all PS4 southbridges. This is in 7.0-Stable but not in this 5.4 bringup.
- ICC `resetBtWlan` + `resetUsbPort` patches if our tree is missing them.
- pci/probe.c phantom-filter if our tree is missing it.

### Plan C — Use bringup as a study-only reference, don't merge (no effort, intel only)

What we're doing now. Good for understanding upstream patterns.
Disadvantage: we won't catch fixes upstream lands afterward.

**Recommendation:** Plan B for now. Run a diff between linux-ps4/ and
`research/baikal-bringup/` to see which rmuxnet-isms are missing, then
selectively apply.

---

## 5. Plans / ideas for the Baikal 6.15+ effort

If we want to contribute upstream to feeRnt's `x_exp__6.15.4-BaikalLove`
or rmuxnet's `ps4-baikal-7.0-port`, the highest-leverage things from this
analysis:

### Idea 1 — Verify ICC `resetUsbPort` is being called on 6.15

Read feeRnt's BaikalLove `bpcie_icc_init` and confirm those calls
survived. If they didn't, that's a 5-line fix that could unblock USB
overnight. Equivalent on rmuxnet's 7.0 port — confirm "USB working"
commit isn't doing what `resetUsbPort` already does.

### Idea 2 — Trace MSI alloc-type compatibility

Add `pr_info("msi_alloc type=%d", arg->type)` at
`bpcie_msi_domain_set_desc` and see what types arrive on 6.x. If
`X86_IRQ_ALLOC_TYPE_PCI_MSI` (newer type) is showing up but the
domain only handles `_MSI`, we have our routing bug. Fix is to accept
both types, or to rename uniformly.

### Idea 3 — Upstream-friendlier IOMMU bypass

Replace `#ifdef CONFIG_X86_PS4` skip with a runtime
`if (boot_params.hdr.hardware_subarch == X86_SUBARCH_PS4)` check.
The TODO comment in the code says exactly this. This could be a tiny
patch to merge into mainline — making the IOMMU init recognize the PS4
subarch.

### Idea 4 — Decouple AHCI probe from xhci-aeolia

Move `ahci_init_one` out of `xhci-aeolia.c` into a small `ahci-aeolia.c`
companion. xhci-aeolia.c stays focused. Reduces churn each time mainline
ahci changes.

### Idea 5 — Tester support for our setup

The hardest blocker is hardware-debug. Both maintainers said in feeRnt
issue #3 that UART logs are gating progress. We have `ps4-uart/`. If
that's functional on a Baikal console, we could publish UART logs from
booting feeRnt's BaikalLove kernel — directly unblock the upstream
effort.

### Idea 6 — Bisect the 5.4→5.15 Baikal regression

Nobody has nailed down which exact 5.x change broke Baikal. Walk
from 5.4 → 5.5 → … → 5.15 with this same patch set, compile each, boot
test (or QEMU emulate?). Whichever version first white-LEDs is the
boundary. Bisect within it for the offending mainline commit. Result is
a stable patch series for everyone forking PS4 Linux upstream.

---

## 6. Concrete assumptions to validate before further work

- [ ] `0xc9000000` BAR4 hardcoded address is what Sony's loader actually
      programs on every Baikal model (CUH-2200, CUH-7200, etc.).
- [ ] Aeolia EMC timer calibrate works on Baikal (or there's a different
      timer needed).
- [ ] `pci_bus_read_dev_vendor_id` 60ms timeout still resolves correctly
      under our build's PCI hot-add timing.
- [ ] `apcie_icc_cmd(0x10, 0, ...)` (i2c-over-ICC) on Baikal correctly
      delegates to `bpcie_icc_cmd` — read `ps4-apcie-icc.c` to confirm.
- [ ] No kernel that compiles this defconfig + bringup successfully
      requires Mesa > 25.1 (per feeRnt issue #8).
- [ ] `bus_master` global flag is safe (it's gated to a single PCI
      driver, but not lock-protected).
- [ ] `ICC_TIMEOUT 15;` (with semicolon) compiles correctly when used
      as `HZ * ICC_TIMEOUT` — that's `HZ * 15;` which works as a stmt
      but is fragile. Cosmetic but worth fixing.

---

## 7. Files NOT yet read in detail (defer if needed)

- `ps4-apcie-icc.c` (589 lines) — Aeolia ICC driver, mirror of bpcie's.
- `drivers/ps4/icc/i2c.c` (158) — i2c bridge over ICC.
- `drivers/ata/ahci.c` PS4 changes (1821 lines added).
- `drivers/gpu/drm/amd/amdgpu/cik.c` PS4 sections (+318).
- `gfx_v7_0.c` PS4 paths (+661).
- `dce_v8_0.c` PS4 sections (+44).
- `gmc_v7_0.c` (+19 lines for GMC layout).

If the next decision is "merge or fork from bringup", reading these
becomes important. If we stay study-only, current depth is sufficient.

---

## 8. Concrete next-step suggestions (in priority order)

1. **Diff** `research/baikal-bringup/` against `linux-ps4/` to see what's
   different. (Both are 5.4 trees; should be a small diff if we're
   already aligned.)
2. **Pull** the rmuxnet `sky2 experimental` patch onto our tree if not
   present.
3. **Inspect** our local linux-ps4 ICC init code to confirm
   `resetUsbPort` and `resetBtWlan` are invoked.
4. **Document** the EMC timer assumption: check what physical address
   Baikal's BAR4 actually lands at on real hardware (compare against
   `0xc9000000`).
5. **Decide:** Plan A vs Plan B vs Plan C from §4. If A, plan a
   step-by-step migration. If B, identify the specific cherry-picks.
6. **Optional:** Read `ps4-apcie-icc.c` and `drivers/ata/ahci.c` PS4
   bits to fill the remaining gaps in §7.
