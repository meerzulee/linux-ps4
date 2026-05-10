#!/usr/bin/env bash
# Experiment 2 — does crashniels' tree boot AS-IS (no patch slicing)?
#
# Hypothesis: our 13-patch slice of crashniels' tree may have dropped
# a hunk, reordered something, or otherwise diverged. Building their
# tree directly (without going through our patch system) controls
# for that.
#
# Method:
#   - cd tmp/crashniels-6.15
#   - Use their own .config + olddefconfig
#   - make -j$(nproc) bzImage
#   - copy result to output/crashniels-vanilla/bzImage
#   - kexec-test it.
#
# Cost: 1 chain (test) + ~5min build, no chains.
# Yield: separates "their bug" from "our bug".
#   - boots → our slicing introduced a regression. Bisect our patches
#     against crashniels' tree.
#   - hangs → upstream issue, not us. Look elsewhere.
#
# Prerequisites:
#   - tmp/crashniels-6.15/ checked out (already done by `make init`).
#   - GCC/Clang available.
set -euo pipefail

cd "$(dirname "$0")/../../.."

REF=tmp/crashniels-6.15
OUT=output/crashniels-vanilla
[[ -d "$REF" ]] || { echo "[x] $REF not found. Run: make init"; exit 1; }
mkdir -p "$OUT"

# crashniels ships their own working config — try that first.
CONFIG_SRC=""
for c in "$REF/config" "$REF/.config" "$REF/arch/x86/configs/baikal_defconfig"; do
  if [[ -f "$c" ]]; then CONFIG_SRC="$c"; break; fi
done

if [[ -z "$CONFIG_SRC" ]]; then
  echo "[!] No crashniels config found in $REF; falling back to our 6.x config."
  CONFIG_SRC=config/6.x-baikal.config
fi

echo "[*] Using config: $CONFIG_SRC"
cp "$CONFIG_SRC" "$REF/.config"

echo "[*] make olddefconfig"
make -C "$REF" olddefconfig

echo "[*] make -j$(nproc) bzImage"
time make -C "$REF" -j"$(nproc)" bzImage

cp -v "$REF/arch/x86/boot/bzImage" "$OUT/bzImage"
ls -la "$OUT/bzImage"

echo
echo "[+] Built. To test:"
echo "    bash scripts/dev/kexec-test.sh $OUT/bzImage \\"
echo "      --initrd checkpoint/boot/initramfs.cpio.gz"
