#!/usr/bin/env bash
# Install one of the canonical bootargs profiles onto the PS4 USB.
#
# Usage:
#   sudo bash scripts/dev/update-bootargs.sh                    # default profile
#   sudo bash scripts/dev/update-bootargs.sh 5.4-normal
#   sudo bash scripts/dev/update-bootargs.sh 6.x-diagnostic
#   sudo bash scripts/dev/update-bootargs.sh 6.x-bypass-systemd
#   sudo bash scripts/dev/update-bootargs.sh --list             # show available profiles
#   sudo bash scripts/dev/update-bootargs.sh --revert           # restore bootargs.txt.prev
#
# Each profile is a plain text file in the repo's bootargs/ directory.
# The previous bootargs.txt is saved as bootargs.txt.prev before any
# overwrite, so --revert always works back one step.
#
# Convention matches scripts/swap-bzimage.sh: mounts /dev/sda1 at
# /mnt/ps4boot, syncs, unmounts. Override DEV/MNT via env vars if needed.
set -euo pipefail

DEFAULT_PROFILE="6.x-diagnostic"

DEV="${DEV:-/dev/sda1}"
MNT="${MNT:-/mnt/ps4boot}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTARGS_DIR="${REPO_ROOT}/bootargs"

usage() {
    cat <<EOF
Install a bootargs profile onto the PS4 USB.

Usage: sudo bash $0 [OPTIONS] [profile]

Profiles (from ${BOOTARGS_DIR##*/}/):
EOF
    if [[ -d "${BOOTARGS_DIR}" ]]; then
        for f in "${BOOTARGS_DIR}"/*.txt; do
            [[ -f "$f" ]] || continue
            local name; name="$(basename "$f" .txt)"
            local default_marker=""
            [[ "$name" = "$DEFAULT_PROFILE" ]] && default_marker=" (default)"
            printf "  %-24s%s\n" "$name" "$default_marker"
        done
    fi
    cat <<EOF

Options:
  -l, --list      Show profiles and exit (no USB needed).
  -r, --revert    Restore bootargs.txt from bootargs.txt.prev.
  -h, --help      This help.

Default profile when none given: ${DEFAULT_PROFILE}
EOF
    exit 0
}

REVERT=false
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -l|--list)
            for f in "${BOOTARGS_DIR}"/*.txt; do
                [[ -f "$f" ]] || continue
                printf "%s\n  %s\n\n" "$(basename "$f" .txt)" "$(cat "$f")"
            done
            exit 0
            ;;
        -r|--revert) REVERT=true; shift ;;
        -*) echo "[x] Unknown option: $1"; usage ;;
        *) PROFILE="$1"; shift ;;
    esac
done

PROFILE="${PROFILE:-$DEFAULT_PROFILE}"
PROFILE_FILE="${BOOTARGS_DIR}/${PROFILE}.txt"

[[ $EUID -eq 0 ]] || { echo "[x] Run as root: sudo bash $0"; exit 1; }
[[ -b "$DEV"   ]] || { echo "[x] $DEV is not a block device — is the USB plugged in?"; exit 1; }

if [[ "$REVERT" = false && ! -f "$PROFILE_FILE" ]]; then
    echo "[x] Unknown profile '$PROFILE'."
    echo "    Available: $(ls "${BOOTARGS_DIR}"/*.txt 2>/dev/null | xargs -n1 -I{} basename {} .txt | tr '\n' ' ')"
    exit 1
fi

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$DEV" "$MNT"

if [[ "$REVERT" = true ]]; then
    if [[ ! -f "$MNT/bootargs.txt.prev" ]]; then
        echo "[x] No $MNT/bootargs.txt.prev to revert to."
        umount "$MNT"; rmdir "$MNT"
        exit 1
    fi
    echo "[*] Reverting:"
    echo "    current:  $(cat "$MNT/bootargs.txt" 2>/dev/null || echo '(missing)')"
    echo "    prev:     $(cat "$MNT/bootargs.txt.prev")"
    cp -f "$MNT/bootargs.txt.prev" "$MNT/bootargs.txt"
    sync
    umount "$MNT"
    rmdir "$MNT"
    echo "[+] Reverted."
    exit 0
fi

echo "=== USB bootargs.txt BEFORE ==="
[[ -f "$MNT/bootargs.txt" ]] && cat "$MNT/bootargs.txt"; echo

# Save previous bootargs.txt for --revert.
if [[ -f "$MNT/bootargs.txt" ]]; then
    cp -f "$MNT/bootargs.txt" "$MNT/bootargs.txt.prev"
fi

# Strip trailing newline before writing — some loaders are picky.
NEW_ARGS="$(tr -d '\n' < "$PROFILE_FILE")"
printf '%s' "$NEW_ARGS" > "$MNT/bootargs.txt"

echo "=== USB bootargs.txt AFTER (profile: $PROFILE) ==="
cat "$MNT/bootargs.txt"; echo
echo

ls -la "$MNT" | grep -E "boot|bzImage|initramfs|^total" || true

sync
umount "$MNT"
rmdir "$MNT"

echo
echo "[+] Done. bootargs.txt installed from profile '$PROFILE'."
echo "    Previous saved as bootargs.txt.prev (revert via --revert)."
echo
echo "Power-cycle the PS4, launch ArabPixel v24b → linux-1024mb.bin via PSFree."
echo "Watch UART with: cd ps4-uart && python3 ps4uart.py live"
