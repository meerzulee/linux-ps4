#!/usr/bin/env bash
# Kexec Linux 6.x with the boomerang initramfs.
#
# If 6.x reaches /init, the initramfs records logs and kexecs back to
# known-good 5.4. If 6.x hangs before /init, manual PS4 recovery is still
# required.
set -euo pipefail

cd "$(dirname "$0")/../.."

BZ="${BZ:-output/6.x-baikal/bzImage}"
INITRD="${INITRD:-output/boomerang-initramfs.cpio.gz}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-360}"
EXTRA="${EXTRA:-init=/init rdinit=/init initcall_debug ignore_loglevel debug printk.devkmsg=on panic=0}"

[[ -f "$BZ" ]] || { echo "[x] Missing 6.x bzImage: $BZ" >&2; exit 1; }
if [[ ! -f "$INITRD" ]]; then
  echo "[!] Missing $INITRD; building it now"
  bash scripts/dev/build-boomerang-initramfs.sh
fi

cat <<EOF
================================================================
 Boomerang kexec test
================================================================
Input kernel : $BZ
Initramfs    : $INITRD
Extra cmdline: $EXTRA

Expected outcomes:
  PASS-ish: SSH disappears, Linux 6 reaches /init, then 5.4 SSH returns.
  FAIL    : SSH never returns; 6.x died before or inside initramfs.

If SSH returns, fetch logs with:
  ssh ps4 'sudo find /var/log/ps4-boomerang -maxdepth 2 -type f -ls 2>/dev/null || true'

EOF

read -p "Press Enter to fire boomerang kexec, Ctrl-C to abort: "

WAIT_TIMEOUT="$WAIT_TIMEOUT" bash scripts/dev/kexec-test.sh "$BZ" \
  --initrd "$INITRD" \
  --cmdline "$EXTRA"
