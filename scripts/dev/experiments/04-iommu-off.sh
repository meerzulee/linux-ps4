#!/usr/bin/env bash
# Experiment 4 — iommu=off + intremap=off
#
# Hypothesis (Tier-1, the top suspect from failure-analysis.md):
# the new x86_fwspec_is_aeolia() predicate in patch 1100 returns
# wrong for Baikal, MSI/IRQ remapping silently fails for downstream
# devices (xHCI, AHCI, sky2). Devices probed → never get IRQs →
# hang at probe.
#
# Disabling IOMMU + interrupt remapping bypasses that whole code
# path. If 6.x boots → that's the cause. Then we dig into
# patches/6.x-baikal/{1000-iommu,1100-pci-msi}/.
#
# Cost: 1 chain.
# Yield:
#   - boots → MSI/IOMMU plumbing is the bug. Top hypothesis confirmed.
#   - hangs → bug is elsewhere. H1 ranked down.
set -euo pipefail
cd "$(dirname "$0")/../../.."

BZ="output/6.x-baikal/bzImage"
INITRD="checkpoint/boot/initramfs.cpio.gz"
[[ -f "$BZ" ]] || { echo "[x] $BZ not found. Run: ./build.sh -t 6.x-baikal"; exit 1; }

echo "[*] Cmdline: iommu=off amd_iommu=off intremap=off + initcall_debug"
echo "[*] Disabling IOMMU may cause some devices to misbehave; that's OK"
echo "    for this experiment — we just want to know if the boot survives."
echo
read -p "Press Enter to fire, Ctrl-C to abort: "

bash scripts/dev/kexec-test.sh "$BZ" \
  --initrd "$INITRD" \
  --cmdline "iommu=off amd_iommu=off intremap=off initcall_debug ignore_loglevel"
