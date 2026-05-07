#!/usr/bin/env bash
# Poll for SSH on the PS4 after YOU manually power-cycled and re-launched
# the Linux payload. Reports PASS/FAIL with timeout.
set -euo pipefail
PS4_HOST="${PS4_HOST:-ps4}"
PS4_IP="${PS4_IP:-192.168.50.125}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

log "Polling SSH on $PS4_IP (timeout ${WAIT_TIMEOUT}s)…"
start=$(date +%s); attempt=0
while true; do
  attempt=$((attempt+1))
  if ssh -o ConnectTimeout=4 -o BatchMode=yes "$PS4_HOST" 'true' 2>/dev/null; then
    new_uname=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$PS4_HOST" 'uname -r' 2>/dev/null || echo unknown)
    new_uptime=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$PS4_HOST" 'uptime' 2>/dev/null || echo unknown)
    if echo "$new_uptime" | grep -qE 'up.{1,3}(min|sec|[0-5]:[0-9][0-9],)'; then
      ok "SSH back. kernel: $new_uname  uptime: $new_uptime"
      exit 0
    fi
  fi
  elapsed=$(($(date +%s) - start))
  if (( elapsed >= WAIT_TIMEOUT )); then
    warn "Timed out after ${elapsed}s."
    cat <<EOF

[!] Likely kernel hung. Recovery:
  1. Hold PS4 power button ~7s.
  2. Plug USB into host.
  3. sudo bash scripts/dev/rollback-kernel.sh
  4. Replug USB into PS4 → re-launch payload.
EOF
    exit 1
  fi
  (( attempt % 6 == 0 )) && log "still waiting (${elapsed}s)"
  sleep 5
done
