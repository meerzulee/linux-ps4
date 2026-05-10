#!/usr/bin/env bash
# Experiment 1 — find the hung initcall on 6.x
#
# Hypothesis: 6.x hangs in some specific initcall function we haven't
# identified. With initcall_debug + ignore_loglevel, the kernel logs
# every initcall as it runs. The last "initcall: <fn>+0x.. ..." line
# printed before the hang names the broken subsystem.
#
# Method:
#   - kexec-test the 6.x bzImage with `initcall_debug ignore_loglevel`.
#   - When kexec-test reports timeout (180s), the kernel has hung.
#   - Photograph HDMI BEFORE you power-cycle. The bottom of the screen
#     shows the last few initcalls. The very last "initcall: <fn>"
#     line is your answer.
#
# Cost: 1 PSFree chain.
# Yield: HIGHEST per chain. Run this FIRST.
#
# Prerequisites:
#   - PS4 booted to known-good 5.4, SSH up.
#   - 6.x bzImage built: ./build.sh -t 6.x-baikal
#   - kexec-tools installed on PS4: sudo pacman -S kexec-tools
#   - `07-uart-capture.sh` running in another terminal (recommended).
set -euo pipefail

cd "$(dirname "$0")/../../.."

BZ="${BZ:-output/6.x-baikal/bzImage}"
INITRD="${INITRD:-checkpoint/boot/initramfs.cpio.gz}"

[[ -f "$BZ" ]] || { echo "[x] $BZ not found. Run: ./build.sh -t 6.x-baikal"; exit 1; }
[[ -f "$INITRD" ]] || { echo "[x] $INITRD not found."; exit 1; }

echo "================================================================"
echo " Experiment 1: initcall_debug"
echo "================================================================"
echo
echo " WHAT TO DO WHEN IT HANGS:"
echo "   1. Don't immediately power-cycle."
echo "   2. Get your phone, photograph the bottom of HDMI."
echo "   3. Look for the last 'initcall: <fn>+0x.. ...' line."
echo "   4. Note also any '[NN.NNNN] WARN:' or 'Oops:' lines."
echo "   5. Compare against checkpoint/docs/uart-boot-capture-ttyS0E000.log"
echo "      to see how far past the working 5.4 you got."
echo "   6. THEN power-cycle and run scripts/dev/rollback-kernel.sh."
echo
echo " The HDMI photo is the experiment result. Save it."
echo
read -p "Press Enter to fire the kexec, Ctrl-C to abort: "

bash scripts/dev/kexec-test.sh "$BZ" \
  --initrd "$INITRD" \
  --cmdline "initcall_debug ignore_loglevel debug printk.devkmsg=on"
