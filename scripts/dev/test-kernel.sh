#!/usr/bin/env bash
# Test a new bzImage on PS4 over SSH with safety net.
#
# Usage:
#   test-kernel.sh <new-bzImage> [label]
#
# What it does:
#   1. Verifies SSH to PS4 works (we need this to be in a sane state to start).
#   2. Snapshots the current USB FAT32 layout into the test record.
#   3. Backs up current active bzImage → bzImage-prev (auto-rollback target).
#   4. Ensures bzImage-stable exists on USB (one-time bootstrap).
#   5. Copies new bzImage as active, syncs FS, unmounts FAT32.
#   6. Triggers `systemctl reboot` on PS4 — PS4 powers off; you re-launch
#      `linux-1024mb.bin` via PSFree manually.
#   7. Polls SSH on the PS4 IP every 5s (default 5 min total).
#   8. Reports:
#        - PASS  : SSH came back; new kernel boots. Suggest `mark-good.sh`.
#        - FAIL  : SSH did not return within timeout. Print rollback steps.
#
# Convention:
#   bzImage         = currently active boot kernel
#   bzImage-stable  = last-known-good fallback (set via mark-good.sh)
#   bzImage-prev    = previous active before this test (auto-restored by rollback-kernel.sh)
set -euo pipefail

PS4_HOST="${PS4_HOST:-ps4}"
PS4_IP="${PS4_IP:-192.168.50.125}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
USB_DEV="${USB_DEV:-/dev/sda1}"
MNT="/mnt/ps4boot"

new_bz="${1:-}"
label="${2:-test-$(date +%H%M%S)}"

if [[ -z "$new_bz" ]]; then
  echo "Usage: $0 <new-bzImage> [label]" >&2
  exit 1
fi
[[ -f "$new_bz" ]] || { echo "[x] Missing $new_bz"; exit 1; }

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

log "Pre-flight: SSH to $PS4_HOST"
ssh -o ConnectTimeout=5 -o BatchMode=yes "$PS4_HOST" 'true' \
  || die "Can't SSH to $PS4_HOST. PS4 not booted, or kernel hung. Use rollback-kernel.sh with USB on host."

log "Pre-flight: pick up current state on USB"
ssh "$PS4_HOST" "sudo mkdir -p $MNT && sudo mount $USB_DEV $MNT" || die "mount failed"
ssh "$PS4_HOST" "ls -la $MNT" | head -20

# Push the new bzImage to PS4
log "scp $new_bz → $PS4_HOST:/tmp/test-bzImage ($(stat -c %s "$new_bz") bytes)"
scp -q "$new_bz" "$PS4_HOST":/tmp/test-bzImage
ssh "$PS4_HOST" "sudo install -m 0644 /tmp/test-bzImage $MNT/bzImage-test"

# Snapshot current active as bzImage-prev (always, every test) and
# bootstrap bzImage-stable if missing.
ssh "$PS4_HOST" "
  set -e
  cd $MNT
  sudo cp -f bzImage bzImage-prev
  if [ ! -f bzImage-stable ]; then
    echo '[*] First test — bootstrapping bzImage-stable from current active'
    sudo cp -f bzImage bzImage-stable
  fi
  sudo install -m 0644 bzImage-test bzImage
  sudo rm -f bzImage-test
  echo '$label $(date -u +%FT%TZ)' | sudo tee .last-test > /dev/null
  ls -la
  cd /
  sync
  sudo umount $MNT && sudo rmdir $MNT 2>/dev/null || true
"

echo
ok "USB staged. New bzImage installed; previous saved as bzImage-prev."
log "**DO NOT auto-reboot.** When you're ready to test, manually:"
log "  1. Power-cycle the PS4 (it's still running the OLD kernel right now)"
log "  2. Re-launch via PSFree → Payload Guest → linux-1024mb.bin"
log "  3. Then run:  bash scripts/dev/wait-for-ssh.sh    # to confirm boot"
exit 0

# Polling logic preserved below in case we ever want a separate observer.
# Currently unused — invoked via wait-for-ssh.sh on demand.
log "Polling for SSH on $PS4_IP (timeout ${WAIT_TIMEOUT}s)..."

start=$(date +%s)
attempt=0
while true; do
  attempt=$((attempt+1))
  # Treat SSH success only as confirmed when uname succeeds AND uptime is fresh
  if ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no "$PS4_HOST" 'true' 2>/dev/null; then
    new_uname=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$PS4_HOST" 'uname -r' 2>/dev/null || echo unknown)
    new_uptime=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$PS4_HOST" 'uptime' 2>/dev/null || echo unknown)
    # 'uptime' immediately after fresh boot has " up X min" or " up XX sec"
    # — we accept anything 0–5 min as "freshly booted".
    if echo "$new_uptime" | grep -qE 'up.{1,3}(min|sec|[0-5]:[0-9][0-9],)'; then
      elapsed=$(($(date +%s) - start))
      ok "SSH returned after ${elapsed}s (attempt $attempt)"
      echo "    kernel: $new_uname"
      echo "    uptime: $new_uptime"
      echo
      ok "Test '$label' PASSED. New kernel is alive."
      log "If you want this to become the new fallback, run:"
      log "    bash scripts/dev/mark-good.sh"
      exit 0
    fi
    # Otherwise this is the OLD kernel still up because reboot hasn't taken
    # effect yet — keep waiting.
  fi
  elapsed=$(($(date +%s) - start))
  if (( elapsed >= WAIT_TIMEOUT )); then
    echo
    warn "Timed out after ${elapsed}s — no SSH on $PS4_IP."
    echo
    cat <<EOF
[!] Test '$label' FAILED. Kernel likely hung or panicked.

Manual recovery:
  1. Hold PS4 power button ~7s to force off.
  2. Plug USB into your host.
  3. Run:
       sudo bash scripts/dev/rollback-kernel.sh
     This restores bzImage from bzImage-stable.
  4. Replug USB into PS4 → re-launch linux-1024mb.bin → SSH back.

Optional: replay any newer-than-stable test with:
       sudo bash scripts/dev/rollback-kernel.sh --to-prev
     (uses bzImage-prev — typically whatever was active before this test)
EOF
    exit 1
  fi
  if (( attempt % 6 == 0 )); then
    log "still waiting (${elapsed}s elapsed)"
  fi
  sleep 5
done
