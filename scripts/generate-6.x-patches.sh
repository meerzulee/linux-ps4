#!/bin/bash
# Generate the 6.x-baikal patch series.
#
# Source = tmp/crashniels-6.15 (HEAD = b3b6b1e4f) on top of vanilla v6.15.4
#          (commit e60eb4415).
# crashniels' tree absorbs feeRnt/whitehax0r 5.4 work plus Liverpool/CIK
# support for radeon, amdkfd, msi-irqdomain refactor handling, and the
# drm_bridge changes — i.e. the Linux 5.4 → 6.15 forward-port has already
# been done by crashniels. We split it back into per-subsystem patches so
# the repo carries an auditable patch stack on top of vanilla.
#
# We additionally apply:
#   - feeRnt's xhci-aeolia Baikal-shutdown fix (b0969f7d101f)
#   - our own bpcie-icc pointer-type fix (also needed under 6.x)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
SRC="${ROOT}/tmp/crashniels-6.15"
DEST="${ROOT}/patches/6.x-baikal"
VBASE="e60eb4415"           # vanilla v6.15.4
HEAD_REV="b3b6b1e4f"        # crashniels HEAD

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[gen6]${NC} $1"; }

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
        echo "Source: crashniels/linux ps4-linux-6.15.y-baikal (HEAD ${HEAD_REV})"
        echo "        on top of vanilla v6.15.4 (${VBASE})."
        echo ""
        echo "---"
        cd "${SRC}"
        git diff --binary "${VBASE}..HEAD" -- "$@"
    } > "${out_path}"

    local lines=$(wc -l < "${out_path}")
    log "$(printf '%-65s %8d lines' "${out}" "${lines}")"
}

log "Generating 6.x-baikal patch series..."
log "  Source: ${SRC}"
log "  Vanilla base: v6.15.4 (${VBASE})"
log "  PS4 head: ${HEAD_REV}"
echo ""

# === 0100: x86 platform ===
make_patch \
    "0100-x86-platform/0001-x86-add-ps4-platform-support.patch" \
    "x86: add PS4 platform support (Linux 6.15)" \
    "Adds the arch/x86/platform/ps4/ subsystem (TSC calibration and platform
init) and the asm/ps4.h interface header. Hooks into x86 Kconfig, head64.c
(early bootparam detection), and bootparam.h.

Note vs 5.4: in 6.15 the MSI subsystem wiring lands in a separate patch
(see 1100-pci-msi/) because MSI moved out of arch/x86/kernel/apic/msi.c
into drivers/pci/msi/." \
    arch/x86/Kconfig \
    arch/x86/include/asm/setup.h \
    arch/x86/include/asm/ps4.h \
    arch/x86/include/uapi/asm/bootparam.h \
    arch/x86/kernel/amd_nb.c \
    arch/x86/kernel/head64.c \
    arch/x86/platform/Makefile \
    arch/x86/platform/ps4/

# === 0200: drivers/ps4 ===
make_patch \
    "0200-ps4-drivers/0001-drivers-ps4-add-aeolia-belize-baikal.patch" \
    "drivers/ps4: add Aeolia/Belize/Baikal southbridge drivers" \
    "Adds drivers/ps4/ containing platform glue for the three PS4 southbridge
families:
  - aeolia.h, ps4-apcie*.c              (Aeolia/Belize, CUH-1xxx)
  - aeolia-baikal.h, baikal.h, ps4-bpcie*.c (Baikal, CUH-2xxx/7xxx)
  - icc/i2c.c                           (Inter-Chip Communication bus)

Each family exposes an MFD-style PCIe device that fans out to ICC, UART,
power button, and other subfunctions used by the rest of the kernel." \
    drivers/Makefile \
    drivers/ps4/

# === 0300: Liverpool GPU support (amdgpu + radeon + amdkfd + drm_bridge) ===
# crashniels supports Liverpool both via amdgpu (modern path) AND radeon
# (legacy path). This is a substantive expansion vs feeRnt's 5.4 work.
make_patch \
    "0300-gpu-liverpool/0001-amdgpu-add-ps4-liverpool-bridge.patch" \
    "drm/amdgpu: add PS4 Liverpool bridge and CIK quirks" \
    "Adds amdgpu/ps4_bridge.c — DRM bridge that translates between the
Liverpool APU (GCN1.1) and the rest of amdgpu. Plus CIK family changes
(cik.c, cik_sdma.c, dce_v8_0.c, gfx_v7_0.c, gmc_v7_0.c) to recognise the
Liverpool ASIC, plus connector/encoder/atombios/IB/ucode/vkms/DM glue." \
    drivers/gpu/drm/amd/amdgpu/ \
    drivers/gpu/drm/amd/include/asic_reg/gmc/gmc_7_1_d.h \
    drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c \
    include/drm/amd_asic_type.h

make_patch \
    "0300-gpu-liverpool/0002-radeon-add-liverpool-cik-support.patch" \
    "drm/radeon: add PS4 Liverpool support to legacy radeon driver" \
    "Adds Liverpool ASIC support to the legacy radeon driver as a fallback
path (mirrors what amdgpu does). Includes a radeon-side ps4_bridge.c plus
modifications across radeon.h, radeon_asic, audio/connectors/device/display,
encoders, IB, PM, UCODE, UVD, VCE, and CIK family files (cik.c, cikd.h,
cik_sdma.c). Not present in 5.4 patches — added by crashniels for 6.x." \
    drivers/gpu/drm/radeon/

make_patch \
    "0300-gpu-liverpool/0003-amdkfd-cik-ps4-quirks.patch" \
    "drm/amdkfd: PS4 CIK / Liverpool quirks" \
    "amdkfd (kernel fusion driver — compute) adjustments needed for
Liverpool. Touches CIK event interrupt path, CRAT topology, device queue
manager, flat memory, kernel queue, packet manager, topology. Not present
in 5.4 work — amdkfd was less mature then; added by crashniels." \
    drivers/gpu/drm/amd/amdkfd/

make_patch \
    "0300-gpu-liverpool/0004-drm-bridge-and-pciids.patch" \
    "drm: bridge/pciids updates for PS4" \
    "Small updates to the DRM bridge core (drm_bridge.c, drm_bridge.h)
and drm_pciids.h needed by the PS4 bridge integration, plus a tiny
crtc_helper change. The bridge core API tightened up between 5.4 and
6.x — these are the changes needed to keep ps4_bridge.c building." \
    drivers/gpu/drm/drm_bridge.c \
    drivers/gpu/drm/drm_crtc_helper.c \
    include/drm/drm_bridge.h \
    include/drm/drm_pciids.h

# === 0400: AHCI ===
make_patch \
    "0400-storage-ahci/0001-ahci-ps4-internal-hdd-quirks.patch" \
    "ata/ahci: PS4 internal HDD quirks (Linux 6.15)" \
    "Modifications to drivers/ata/ahci.{c,h} for the PS4 internal SATA
controller. Equivalent to the 5.4 patch but rebased on 6.15 ahci changes
(host_alloc/release lifecycle and the runtime PM additions)." \
    drivers/ata/ahci.c \
    drivers/ata/ahci.h

# === 0500: SDHCI/SDIO ===
make_patch \
    "0500-storage-sdio/0001-sdhci-pci-ps4-quirks.patch" \
    "mmc: sdhci-pci: PS4 host controller quirks" \
    "Adds PS4-specific quirks to sdhci-pci-core for the SDIO host that
attaches MT7668 (Baikal) or 88w8897 (Belize) WiFi/BT modules.
6.x-equivalent of the 5.4 sdhci patch." \
    drivers/mmc/host/sdhci-pci-core.c \
    drivers/mmc/host/sdhci-pci.h

# === 0700: sky2 ethernet ===
make_patch \
    "0700-network-sky2/0001-sky2-ps4-quirks.patch" \
    "net: sky2: PS4 Marvell Yukon quirks" \
    "PS4 ships Marvell Yukon 88E8059/88E8079 gigabit ethernet attached
via the southbridge. sky2 needs probe and PHY tweaks to come up cleanly.
6.x-equivalent of the 5.4 sky2 patch." \
    drivers/net/ethernet/marvell/sky2.c \
    drivers/net/ethernet/marvell/sky2.h

# === 0800: USB (xhci-aeolia) ===
make_patch \
    "0800-usb-aeolia/0001-xhci-aeolia-controller.patch" \
    "usb/xhci: add Aeolia/Baikal xHCI controller" \
    "Adds drivers/usb/host/xhci-aeolia.{c,h} — custom xHCI front-end for
the PS4 southbridge USB controllers, plus Kconfig/Makefile wiring and
small xhci.{c,h} hooks. 6.x port retains the structure from 5.4 but
adapts to xhci core API changes (hcd_priv layout, register_companion
removal)." \
    drivers/usb/host/Kconfig \
    drivers/usb/host/Makefile \
    drivers/usb/host/xhci.c \
    drivers/usb/host/xhci.h \
    drivers/usb/host/xhci-aeolia.c \
    drivers/usb/host/xhci-aeolia.h

# === 0900: hwmon ===
make_patch \
    "0900-hwmon/0001-hwmon-fam15h-k10temp-ps4.patch" \
    "hwmon: fam15h_power/k10temp: recognise PS4 APU" \
    "Tiny additions so fam15h_power and k10temp recognise the Liverpool APU
(family 15h, custom DID) and expose temperature/power readings." \
    drivers/hwmon/fam15h_power.c \
    drivers/hwmon/k10temp.c

# === 1000: AMD IOMMU (moved in 6.x to drivers/iommu/amd/) ===
make_patch \
    "1000-iommu/0001-amd-iommu-ps4-init.patch" \
    "iommu/amd: PS4 init quirks (Linux 6.15)" \
    "AMD IOMMU init/iommu path adjustments for Liverpool. NB: in 6.x the
AMD IOMMU code moved from drivers/iommu/amd_iommu_init.c to
drivers/iommu/amd/{init.c,iommu.c} — this patch matches the new layout." \
    drivers/iommu/amd/

# === 1100: PCI / MSI / IRQ-domain (heavily refactored vs 5.4) ===
make_patch \
    "1100-pci-msi/0001-pci-msi-irqdomain-ps4-quirks.patch" \
    "pci/msi/irqdomain: PS4 vendor quirks (Linux 6.15)" \
    "Adds PS4 vendor IDs to pci_ids.h plus probe/MSI-allocation adjustments
needed by the southbridge MFD glue. In 6.x the MSI subsystem was
restructured: arch/x86/kernel/apic/msi.c was replaced by io_apic.c +
vector.c + drivers/pci/msi/irqdomain.c + kernel/irq/irqdomain.c, and
include/linux/msi.h gained a new structure layout. This patch covers
all of that." \
    arch/x86/include/asm/apic.h \
    arch/x86/include/asm/irqdomain.h \
    arch/x86/kernel/apic/io_apic.c \
    arch/x86/kernel/apic/vector.c \
    drivers/pci/msi/irqdomain.c \
    drivers/pci/probe.c \
    include/linux/msi.h \
    include/linux/pci_ids.h \
    kernel/irq/irqdomain.c \
    kernel/irq/msi.c

echo ""
log "Done. Summary:"
find "${DEST}" -name '*.patch' | sort | xargs -I{} sh -c 'printf "  %s  %5d lines\n" "{}" "$(wc -l < "{}")"' | sed "s|${DEST}/||"
echo ""
log "Total:"
find "${DEST}" -name '*.patch' -exec wc -l {} + | tail -1
