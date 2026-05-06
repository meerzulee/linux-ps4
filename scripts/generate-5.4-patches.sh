#!/bin/bash
# Generate the canonical 5.4-baikal patch series by bucketing the feeRnt
# 5.4.247-baikal diff against vanilla v5.4.247.
#
# Source repo:   tmp/feeRnt-5.4.247-baikal (HEAD = 1fdfbd9a4)
# Vanilla base:  v5.4.247 (kernel.org SHA 61a2f83e4762ee0c766f86944e612305f5888bcb)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
SRC="${ROOT}/tmp/feeRnt-5.4.247-baikal"
DEST="${ROOT}/patches/5.4-baikal"
VBASE="61a2f83e4762ee0c766f86944e612305f5888bcb"
HEAD_REV="1fdfbd9a4"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[gen]${NC} $1"; }

# make_patch <out-relative-to-DEST> <subject> <description> <path1> [path2 ...]
make_patch() {
    local out="$1"; shift
    local subject="$1"; shift
    local desc="$1"; shift
    local out_path="${DEST}/${out}"
    mkdir -p "$(dirname "${out_path}")"

    {
        echo "From: PS4 Linux Baikal Port <noreply@ps4-linux>"
        echo "Subject: [PATCH] ${subject}"
        echo ""
        echo "${desc}"
        echo ""
        echo "Extracted from feeRnt/ps4-linux-12xx branch 5.4.247-baikal-dfaus"
        echo "(HEAD ${HEAD_REV}) versus vanilla v5.4.247 (kernel.org)."
        echo ""
        echo "---"
        cd "${SRC}"
        git diff --binary "${VBASE}..HEAD" -- "$@"
    } > "${out_path}"

    local lines=$(wc -l < "${out_path}")
    log "$(printf '%-60s %8d lines' "${out}" "${lines}")"
}

log "Generating 5.4-baikal patch series..."
log "  Source: ${SRC}"
log "  Vanilla base: v5.4.247 (${VBASE:0:12})"
log "  PS4 head: ${HEAD_REV}"
echo ""

# === 0100: x86 platform ===
make_patch \
    "0100-x86-platform/0001-x86-add-ps4-platform-support.patch" \
    "x86: add PS4 platform support" \
    "Adds the arch/x86/platform/ps4/ subsystem with TSC calibration and platform
init for Sony PS4. Hooks into x86 Kconfig, head64.c (early bootparam
detection), MSI/IRQ subsystem, and adds the asm/ps4.h interface header." \
    arch/x86/Kconfig \
    arch/x86/entry/Makefile \
    arch/x86/include/asm/msi.h \
    arch/x86/include/asm/setup.h \
    arch/x86/include/uapi/asm/bootparam.h \
    arch/x86/include/asm/ps4.h \
    arch/x86/kernel/amd_nb.c \
    arch/x86/kernel/apic/msi.c \
    arch/x86/kernel/head64.c \
    arch/x86/platform/Makefile \
    arch/x86/platform/ps4/

# === 0200: drivers/ps4 (Aeolia/Belize/Baikal southbridge core) ===
make_patch \
    "0200-ps4-drivers/0001-drivers-ps4-add-aeolia-belize-baikal.patch" \
    "drivers/ps4: add Aeolia/Belize/Baikal southbridge drivers" \
    "Adds drivers/ps4/ containing platform glue for the three PS4 southbridge
families:
  - aeolia.h, ps4-apcie*.c   (Aeolia/Belize CUH-1xxx)
  - aeolia-baikal.h, baikal.h, ps4-bpcie*.c (Baikal CUH-2xxx/7xxx)
  - icc/i2c.c                (Inter-Chip Communication bus)

Each family exposes an MFD-style PCIe device that fans out to ICC, UART,
power button, and other subfunctions used by the rest of the kernel." \
    drivers/Makefile \
    drivers/mfd/Kconfig \
    drivers/ps4/

# === 0300: Liverpool GPU (amdgpu ps4_bridge) ===
make_patch \
    "0300-gpu-liverpool/0001-amdgpu-add-ps4-liverpool-bridge.patch" \
    "drm/amdgpu: add PS4 Liverpool bridge and CIK quirks" \
    "Adds ps4_bridge.c — a DRM bridge that translates between the AMD GCN1.1
'Liverpool' APU in the PS4 and the rest of amdgpu. Modifies the CIK family
(cik.c, cik_sdma.c, dce_v8_0.c, dce_virtual.c, gfx_v7_0.c, gmc_v7_0.c) to
recognise the Liverpool ASIC, plus connector/encoder/atombios glue and a
small drm_crtc_helper change." \
    drivers/gpu/drm/amd/amdgpu/ \
    drivers/gpu/drm/amd/amdkfd/kfd_device.c \
    drivers/gpu/drm/amd/include/asic_reg/gmc/gmc_7_1_d.h \
    drivers/gpu/drm/drm_crtc_helper.c \
    include/drm/amd_asic_type.h

# === 0400: AHCI storage (PS4 SATA quirks) ===
make_patch \
    "0400-storage-ahci/0001-ahci-ps4-internal-hdd-quirks.patch" \
    "ata/ahci: add PS4 internal HDD quirks" \
    "Modifies drivers/ata/ahci.{c,h} for the PS4's internal SATA controller —
an unusual AHCI variant that needs custom probe sequencing and several
register-level workarounds before disks enumerate." \
    drivers/ata/ahci.c \
    drivers/ata/ahci.h

# === 0500: SDIO/MMC (sdhci-pci for WiFi/BT host controller) ===
make_patch \
    "0500-storage-sdio/0001-sdhci-pci-ps4-quirks.patch" \
    "mmc: sdhci-pci: add PS4 host controller quirks" \
    "Adds PS4-specific quirks to sdhci-pci-core for the SDIO host that
attaches MT7668 (Baikal) or 88w8897 (Belize) WiFi/BT modules." \
    drivers/mmc/host/sdhci-pci-core.c \
    drivers/mmc/host/sdhci-pci.h

# === 0600: WiFi/BT MT7668 ===
make_patch \
    "0600-wifi-mt7668/0001-mediatek-mt7668-driver-merge.patch" \
    "net/wireless/mediatek: add MT7668 driver tree" \
    "Imports the MediaTek MT7668 WiFi/BT driver tree into
drivers/net/wireless/mediatek/. This is a vendor codebase distinct from
the upstream mt76 driver, taken from Sony and refined by feeRnt." \
    drivers/net/wireless/mediatek/

# === 0700: sky2 ethernet ===
make_patch \
    "0700-network-sky2/0001-sky2-ps4-quirks.patch" \
    "net: sky2: add PS4 Marvell Yukon quirks" \
    "PS4 ships a Marvell Yukon 88E8059/88E8079 gigabit ethernet attached via
the Aeolia/Baikal southbridge. Standard sky2 needs probe and PHY tweaks
to come up cleanly." \
    drivers/net/ethernet/marvell/sky2.c \
    drivers/net/ethernet/marvell/sky2.h

# === 0800: USB (xhci-aeolia) ===
make_patch \
    "0800-usb-aeolia/0001-xhci-aeolia-controller.patch" \
    "usb/xhci: add Aeolia/Baikal xHCI controller" \
    "Adds drivers/usb/host/xhci-aeolia.{c,h} — a custom xHCI front-end for
the PS4 southbridge USB controllers, plus the Kconfig/Makefile wiring and
small xhci.{c,h} hooks the front-end depends on." \
    drivers/usb/host/Kconfig \
    drivers/usb/host/Makefile \
    drivers/usb/host/xhci.c \
    drivers/usb/host/xhci.h \
    drivers/usb/host/xhci-aeolia.c \
    drivers/usb/host/xhci-aeolia.h

# === 0900: hwmon (fam15h_power, k10temp) ===
make_patch \
    "0900-hwmon/0001-hwmon-fam15h-k10temp-ps4.patch" \
    "hwmon: fam15h_power/k10temp: recognise PS4 APU" \
    "Tiny additions so fam15h_power and k10temp recognise the Liverpool APU
(family 15h, custom DID) and expose temperature/power readings." \
    drivers/hwmon/fam15h_power.c \
    drivers/hwmon/k10temp.c

# === 1000: AMD IOMMU ===
make_patch \
    "1000-iommu/0001-amd-iommu-ps4-init.patch" \
    "iommu/amd: PS4 init quirks" \
    "AMD IOMMU init path needs a small workaround on Liverpool because the
APU advertises IOMMU caps but the southbridge expects late init ordering." \
    drivers/iommu/amd_iommu_init.c

# === 1100: PCI/MSI quirks ===
make_patch \
    "1100-pci-msi/0001-pci-msi-ps4-quirks.patch" \
    "pci/msi: PS4 vendor-specific quirks" \
    "Adds PS4 vendor IDs to pci_ids.h and small probe/MSI-allocation
adjustments needed by the southbridge MFD glue." \
    drivers/pci/probe.c \
    include/linux/pci_ids.h \
    kernel/irq/msi.c

# === 1200: misc ===
make_patch \
    "1200-misc/0001-misc-bootparam-and-gitignore.patch" \
    "misc: bootparam and .gitignore touch-ups" \
    "Catch-all for the few remaining vanilla file changes that do not
belong to a specific subsystem patch." \
    .gitignore

echo ""
log "Done. Files generated under ${DEST}/"
log "Verify totals:"
find "${DEST}" -name '*.patch' -exec wc -l {} + | tail -1
