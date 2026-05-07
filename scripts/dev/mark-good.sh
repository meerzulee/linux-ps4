#!/usr/bin/env bash
# Promote the currently-active bzImage on the PS4 USB to "stable" (the
# fallback that rollback-kernel.sh restores when a kernel test hangs).
#
# Run from the host while PS4 is up and SSH-reachable:
#   bash scripts/dev/mark-good.sh
set -euo pipefail

PS4_HOST="${PS4_HOST:-ps4}"
USB_DEV="${USB_DEV:-/dev/sda1}"
MNT="/mnt/ps4boot"

ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

ssh -o ConnectTimeout=5 -o BatchMode=yes "$PS4_HOST" 'true' \
  || die "Can't SSH to $PS4_HOST. We need a live PS4 to mark its kernel as stable."

log "Mounting $USB_DEV on PS4 to update bzImage-stable"
ssh "$PS4_HOST" "
  set -e
  sudo mkdir -p $MNT
  sudo mount $USB_DEV $MNT
  cd $MNT
  echo 'Before:'
  ls -la bzImage bzImage-stable 2>/dev/null
  if cmp -s bzImage bzImage-stable 2>/dev/null; then
    echo '[*] Active and stable already match — nothing to do.'
  else
    sudo install -m 0644 bzImage bzImage-stable
    echo '[+] bzImage-stable updated to match current active.'
    ls -la bzImage bzImage-stable
  fi
  cd /
  sync
  sudo umount $MNT && sudo rmdir $MNT 2>/dev/null || true
"
ok "Promotion complete. Future failed tests will roll back to this kernel."
