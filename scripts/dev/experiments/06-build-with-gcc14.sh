#!/usr/bin/env bash
# Experiment 6 — rebuild 6.x with GCC 14 instead of GCC 15
#
# Hypothesis: GCC 15 is recent. Codegen regressions in head_64.S,
# IRQ vector dispatch, or SMP startup paths could cause silent
# kernel hangs. crashniels likely built with GCC 13/14 when their
# tree was published; we use whatever Arch ships (currently 15).
#
# Cost: 1 chain (test) + ~5 min (build), plus install GCC 14 (~10
# min) if not already present.
# Yield:
#   - boots → toolchain regression. Either pin GCC 14 in our
#     project or look at codegen diffs.
#   - hangs → not toolchain. Cross H5 off the suspect list.
#
# Prerequisites:
#   - GCC 14 toolchain. On Arch:
#       sudo pacman -S gcc14
#     (if the package isn't available, use AUR or build from source).
#     Verify: gcc-14 --version
set -euo pipefail
cd "$(dirname "$0")/../../.."

if ! command -v gcc-14 >/dev/null 2>&1; then
  echo "[x] gcc-14 not found in PATH."
  echo "    On Arch: sudo pacman -S gcc14"
  echo "    Or use AUR / build from source."
  exit 1
fi

echo "[*] gcc-14: $(gcc-14 --version | head -1)"
echo "[*] Building 6.x with CC=gcc-14"

CC=gcc-14 HOSTCC=gcc-14 ./build.sh -t 6.x-baikal -c

mkdir -p output/6.x-baikal-gcc14
cp -v output/6.x-baikal/bzImage output/6.x-baikal-gcc14/bzImage

echo
echo "[+] Built. To test:"
echo "    bash scripts/dev/kexec-test.sh output/6.x-baikal-gcc14/bzImage \\"
echo "      --initrd checkpoint/boot/initramfs.cpio.gz \\"
echo "      --cmdline 'initcall_debug ignore_loglevel'"
