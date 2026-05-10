#!/usr/bin/env bash
# Experiment 7 — auto-capture UART to a timestamped log file
#
# Process improvement, not a kernel test. Run this in a separate
# terminal BEFORE every kexec-test or boot test. Compounds value
# of every other experiment because you have a permanent searchable
# transcript instead of relying on phone photos.
#
# Cost: 0 chains.
# Yield: every test now produces logs/uart-YYYYMMDD-HHMMSS.log.
#
# Detects which UART tool is available, in order: tio > picocom > screen.
# The PS4 cable is typically /dev/ttyUSB0 on the host.
#
# Usage:
#   07-uart-capture.sh                    # auto-pick tool, /dev/ttyUSB0, 115200
#   07-uart-capture.sh /dev/ttyUSB1
#   DEV=/dev/ttyUSB0 BAUD=115200 07-uart-capture.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."

DEV="${1:-${DEV:-/dev/ttyUSB0}}"
BAUD="${BAUD:-115200}"
LOGDIR="logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/uart-$(date +%Y%m%d-%H%M%S).log"

if [[ ! -c "$DEV" ]]; then
  echo "[x] $DEV is not a character device. Plug the UART cable in?" >&2
  ls -la /dev/ttyUSB* 2>/dev/null || echo "    No /dev/ttyUSB* devices found."
  exit 1
fi

# Make sure user can read the device (typically dialout/uucp group).
if [[ ! -r "$DEV" ]]; then
  echo "[!] $DEV not readable by current user. Try:"
  echo "    sudo usermod -aG uucp $USER  (or 'dialout' on Debian)"
  echo "    Then log out / in. As a workaround, run with sudo:"
  echo "      sudo $0 $DEV"
  exit 1
fi

echo "================================================================"
echo " UART capture"
echo " Device : $DEV"
echo " Baud   : $BAUD"
echo " Log    : $LOG"
echo "================================================================"
echo

if command -v tio >/dev/null 2>&1; then
  echo "[*] Using tio. Press Ctrl-T q to quit."
  exec tio --baudrate "$BAUD" --log --log-file "$LOG" "$DEV"
elif command -v picocom >/dev/null 2>&1; then
  echo "[*] Using picocom. Press Ctrl-A Ctrl-X to quit."
  exec picocom -b "$BAUD" --logfile "$LOG" "$DEV"
elif command -v screen >/dev/null 2>&1; then
  echo "[*] Using screen with logging. Press Ctrl-A k to quit."
  exec screen -L -Logfile "$LOG" "$DEV" "$BAUD"
else
  echo "[x] No UART tool found. Install one of:"
  echo "    sudo pacman -S tio       (preferred)"
  echo "    sudo pacman -S picocom"
  echo "    sudo pacman -S screen"
  exit 1
fi
