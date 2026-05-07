# 03 — The 5.4 patch set

13 patches in 12 directories. Together they teach Linux 5.4.247 about
the PS4 Baikal hardware. This is the **working baseline** — boots to
KDE + WiFi + SSH on real hardware.

The patches are sourced from feeRnt's `5.4.247-baikal-dfaus` branch,
diffed against vanilla `v5.4.247`, and bucketed by subsystem. 100%
file coverage (i.e., applying these patches reproduces the feeRnt
tree byte-for-byte, modulo the local `-mhard-float` fix).

Apply order is `patches/5.4-baikal/series`. Within a directory, files
apply alphabetically (0001-, 0002-, ...).

## 0100-x86-platform — the foundation

**Purpose**: Tell the kernel "this is a PS4" early enough that
PS4-specific code can hook in.

- **0001-x86-add-ps4-platform-support.patch** — Adds:
  - `arch/x86/platform/ps4/ps4.c` — platform init, dummy RTC stubs,
    `apcie_status()` / `bpcie_status()` exports.
  - `arch/x86/platform/ps4/calibrate.c` — TSC calibration via Aeolia's
    EMC timer at 32.768kHz (the platform doesn't have a usable PIT).
  - `arch/x86/include/asm/ps4.h` — public interface header.
  - Modification to `arch/x86/kernel/head64.c` to dispatch on
    `X86_SUBARCH_PS4` from bootparams and call `x86_ps4_early_setup()`
    before generic init.
  - Adds AMD Ryzen `16H_M41H` family to `arch/x86/kernel/amd_nb.c`
    (Jaguar's family ID isn't recognized by mainline).
  - Exports `irq_msi_compose_msg()` as a public symbol for the
    southbridge MSI driver.

You can think of this group as "make the kernel x86-PS4-aware". Every
later patch group depends on this being applied first.

## 0200-ps4-drivers — the southbridge

**Purpose**: Add the multi-function drivers for Aeolia, Belize, and
Baikal southbridges. This is the "PS4-specific stuff that doesn't
fit anywhere in mainline" group.

- **0001-drivers-ps4-add-aeolia-belize-baikal.patch** (~55KB) — Adds
  the `drivers/ps4/` directory tree:
  - `ps4-apcie*.c` — Aeolia/Belize/Baikal "auxiliary PCIe" multi-func
    driver. Probes function 0x14.4 of the southbridge, fans out to
    children (UART, ICC, RTC, power button).
  - `ps4-bpcie*.c` — same idea but for the Baikal-specific BPCIe
    function (PCI ID `0x90D7`–`0x90DE`). Handles bus enumeration and
    MSI setup.
  - `icc/i2c.c` — ICC (Inter-Chip Communication) protocol. Mailbox-
    based duplex queue between Linux and the EAP firmware coprocessor.
  - PCI device IDs: 24 IDs covering all three southbridge families.

  The driver registers UART subfunctions via
  `serial8250_register_8250_port()` for each of the 4 BPCIe UARTs.

- **0002-ps4-bpcie-uart-set-port-type.patch** — **Critical UART fix.**
  Single small patch to `drivers/ps4/ps4-bpcie-uart.c`:
  ```
  -    uart.port.flags  = UPF_SHARE_IRQ;
  +    uart.port.flags  = UPF_SHARE_IRQ | UPF_FIXED_TYPE;
       uart.port.iotype = UPIO_MEM32;
       ...
  +    uart.port.type   = PORT_16550A;
  ```
  Without this, the 8250 autoconfig code probes the BPCIe UART, fails
  (it's not a *standard* 16550A — close, but not quite), sets
  `port.type = PORT_UNKNOWN`, and then the 8250 console layer refuses
  all reads/writes on that port. Forcing `PORT_16550A` plus the
  `UPF_FIXED_TYPE` flag tells the driver "I know what this is; don't
  re-probe me". With this patch applied: `/proc/tty/driver/serial`
  shows `uart:16550A` for both UARTs, and writes succeed.

  **This patch works in 5.4. The same patch triple-faults on 6.x
  during kexec.** That's why it's currently disabled in
  `patches/6.x-baikal/series`. Mystery to be solved — see
  [04-patches-6.x.md](04-patches-6.x.md) and [05-uart.md](05-uart.md).

  Caveat: the patch makes ttySN devices "registered and addressable",
  but **transmit still doesn't actually deliver bytes** —
  `tx_counter` stays 0. There's a deeper issue with the FIFO setup
  or buffer pointers we haven't tracked down. Reads work; writes
  silently drop. Workaround for late-boot UART: rely on `earlycon`
  for boot, then HDMI fbcon for everything else.

## 0300-gpu-liverpool — the GPU

**Purpose**: Recognize Liverpool / Gladius GPUs in amdgpu and bring
up the HDMI bridge.

- **0001-amdgpu-add-ps4-liverpool-bridge.patch** — Adds:
  - `ps4_bridge.c` — DRM bridge connector. Liverpool's display output
    isn't on a real DisplayPort; it's an internal bridge to an HDMI
    encoder. The bridge driver provides `get_modes()`, `detect()`,
    `mode_valid()` so the DRM core can talk to the HDMI port.
  - PCI device IDs for `CHIP_LIVERPOOL` (`0x9920/0x9922/0x9923`) and
    `CHIP_GLADIUS` (`0x9924`) added to the CIK family init.
  - Custom cursor sizes (64×64 vs the default 128×128).
  - Display engine quirks (DCE10 path; not DCN since Liverpool predates
    Vega).

- **0002-amdgpu-dc-drop-mhard-float-for-modern-clang.patch** — Local
  fix. Removes `-mhard-float` from 5 `Makefile`s under
  `drivers/gpu/drm/amd/display/dc/` (calcs, dml, dsc, dcn20, dcn21).
  Clang 16+ removed support for this flag (it's a no-op on x86_64
  anyway; FPU is always present). feeRnt's CI pinned Clang 14 so they
  never hit this. We use Clang 22, so we needed this to compile.

## 0400-storage-ahci — the internal HDD

**Purpose**: PS4's SATA HBA isn't a stock AHCI controller. It needs
custom probe order, custom PHY init, and 31-bit DMA mask.

- **0001-ahci-ps4-internal-hdd-quirks.patch** (~1800 lines) —
  - Adds PCI IDs for all three southbridge AHCI variants.
  - Sets DMA mask to 31-bit (PS4 hardware limitation; standard AHCI
    uses 64-bit).
  - For Baikal specifically: `ahci_pci_bar = AHCI_PCI_BAR0_BAIKAL`
    (BAR0, not standard BAR5).
  - Includes `bpcie_sata_phy_init()` — a hand-translated decompilation
    of the Baikal firmware's SATA PHY initialization sequence.
    Register writes at offsets 0x20A0, 0x2590, 0x2DC0, etc. **This
    code is essentially verbatim from RE'd silicon firmware** — if
    something in this patch breaks, it's hard to diagnose because
    we don't have the original spec, only the working sequence.

  **Likely 6.x risk**: the DMA mask API changed substantially
  between 5.4 and 6.x (`dma_set_mask` semantics, coherent vs
  streaming). Worth a careful re-read of the 6.x version.

## 0500-storage-sdio — the WiFi/BT host bus

**Purpose**: PS4 uses an SDIO host as the bus to the MT7668 WiFi/BT
combo module. The host controller needs custom probe, BAR mapping,
and DMA quirks.

- **0001-sdhci-pci-ps4-quirks.patch** —
  - Adds Aeolia/Belize/Baikal SDHCI PCI IDs.
  - `aeolia_probe_slot()` — defers until `apcie_status() == 0`
    (waits for southbridge ready).
  - `aeolia_enable_dma()` — sets 31-bit DMA mask.
  - Refactors `sdhci_pci_probe_slot()` signature to use
    `chip->first_bar` instead of a parameter, allowing per-chip
    BAR customization.

## 0600-wifi-mt7668 — WiFi/BT (5.4 only)

**Purpose**: The actual MediaTek MT76x8-series WiFi+BT combo driver.
This is a vendor blob, not in mainline, very large.

- **0001-mediatek-mt7668-driver-merge.patch** (~214K lines) — Adds
  the entire `drivers/net/wireless/mediatek/mt76x8/` tree.
  - Vendor MTK driver: 802.11n, WPA2, vendor APIs.
  - Bluetooth: skipped (kernel 5.x has `btmtk` in tree; vendoring
    duplicates causes conflicts).
  - Includes firmware blobs.

  **NOT yet ported to 6.x.** That's documented in
  `patches/6.x-baikal/9000-todo/README.md`. WiFi-less 6.x is OK for
  now; ethernet over sky2 works (when sky2 itself works).

  This is a single huge independent patch; if its compile fails it
  doesn't block the rest of the kernel.

## 0700-network-sky2 — gigabit ethernet

**Purpose**: Marvell Yukon `88E8059/79` GbE on PS4 needs PHY-address
quirks and Aeolia-IRQ routing.

- **0001-sky2-ps4-quirks.patch** —
  - Adds Aeolia/Belize sky2 PCI IDs (Baikal GBE ID is commented out
    — apparently absent or unconfirmed on Baikal hardware).
  - PHY address handling: Aeolia has an L2 switch at MDIO addr 2 and
    a normal PHY at addr 1. Patch makes `phy_addr` dynamic instead
    of the hardcoded `PHY_ADDR_MARV`.
  - Disables PHY reset on Sony devices (PHY reset hangs the chain).
  - MAC address is read from the SPM bootparam region via `mem`
    function 7 (custom Sony storage location).
  - 31-bit DMA mask.
  - Uses `apcie_assign_irqs()` + custom MSI test, falling back to
    standard MSI if the apcie path fails.

  **PLAN.md notes Baikal sky2 is currently broken in practice** —
  the LAN interface comes up but doesn't pass useful traffic. WiFi
  is the working path on Baikal.

## 0800-usb-aeolia — USB host

**Purpose**: PS4's xHCI is integrated as a southbridge function with
multiple HCD instances per PCI device. Stock xhci-pci doesn't handle
this layout.

- **0001-xhci-aeolia-controller.patch** — Adds
  `drivers/usb/host/xhci-aeolia.c`:
  - `xhci_aeolia_probe_one()` — allocates USB2 + USB3 HCDs per
    controller instance.
  - Maps BARs 0, 2, 4 to USB host controllers (3 per device).
  - Shares IRQs with `IRQF_SHARED`.
  - Sets `XHCI_PLAT | XHCI_PLAT_DMA` quirks to disable standard MSI
    and defer DMA mask.

## 0900-hwmon — power and temperature

**Purpose**: Liverpool's CPU has standard AMD power and temperature
sensors, but they're behind unrecognized PCI device IDs.

- **0001-hwmon-fam15h-k10temp-ps4.patch** — Single-line additions:
  - `fam15h_power_id_table[]`: add `PCI_DEVICE_ID_AMD_16H_M41H_F4`.
  - `k10temp_id_table[]`: add `PCI_DEVICE_ID_AMD_16H_M41H_F3`.
  - Result: `/sys/class/hwmon/hwmonX/{power,temp}_input` exposes
    Liverpool sensors via the standard interfaces.

## 1000-iommu — AMD IOMMU quirks

**Purpose**: Liverpool's AMD IOMMU advertises caps the kernel can't
actually use because the southbridge doesn't have a standard IOAPIC.

- **0001-amd-iommu-ps4-init.patch** — Comments out (via
  `#ifndef CONFIG_X86_PS4`):
  - `IOAPIC_SB_DEVID` define and the `check_ioapic_information()`
    call.
  - `amd_iommu_irq_remap` check in `early_amd_iommu_init()`.

  The TODO comment on the patch is "this should detect ps4-ness at
  runtime" — so it's a hack waiting for proper firmware/PCI-config
  detection. Works because we always build with `CONFIG_X86_PS4=y`.

## 1100-pci-msi — PCI quirks and MSI fixes

**Purpose**: Make stock kernel know about Sony PCI vendor, skip
phantom Aeolia PCI functions, and survive non-standard MSI paths.

- **0001-pci-msi-ps4-quirks.patch** —
  - `include/linux/pci_ids.h` — adds Sony vendor `0x104D` and 24
    device IDs (Aeolia 0x908F–0x90A4, Belize 0x90C8–0x90CF, Baikal
    0x90D7–0x90DE).
  - `drivers/pci/probe.c` — `pci_scan_slot()` skips phantom Aeolia
    functions at `devfn != slot 20` when vendor is Sony (these
    bleed through PCI address space spuriously and confuse
    enumeration).
  - `kernel/irq/msi.c` — `msi_domain_prepare_irqs()` only calls
    `msi_prepare` if `ops->msi_prepare` is non-null (PS4's custom
    MSI path doesn't always provide this; without the check, NULL
    deref).

## 1200-misc — bootparam enum and gitignore

**Purpose**: Add the `X86_SUBARCH_PS4` enum value used by 0100, plus
some gitignore tidiness.

- **0001-misc-bootparam-and-gitignore.patch** — One-liner enum value
  in `include/uapi/asm/bootparam.h`, plus `.gitignore` updates.

## Patches most likely to break in 6.x

This is the cliffhanger for [04-patches-6.x.md](04-patches-6.x.md).
Ranked by risk:

1. **0200/0002 (BPCIe UART port.type)** — confirmed broken in 6.x;
   triple-faults at kexec. Currently disabled in 6.x series.
2. **0300/0001 (amdgpu Liverpool bridge)** — DRM is volatile;
   `drm_bridge_funcs` and helper APIs changed extensively 5.4→6.x.
3. **0400/0001 (AHCI PHY init)** — DMA mask API changed; PHY init
   sequence is RE'd firmware that may interact with new ahci core.
4. **1000/0001 (AMD IOMMU)** — directory moved
   (`drivers/iommu/amd_iommu_init.c` → `drivers/iommu/amd/init.c`),
   `check_ioapic_information()` may be gone.
5. **1100/0001 (PCI MSI)** — heavy refactor.
   `arch/x86/kernel/apic/msi.c` was split across `vector.c`,
   `io_apic.c`, `irqdomain.c`. The whole `msi_domain_prepare_irqs`
   path is different.

Next: [04-patches-6.x.md](04-patches-6.x.md) — the 6.x port status, what API changes
were absorbed, and where it likely hangs.
