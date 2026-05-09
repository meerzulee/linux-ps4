#!/bin/bash
# boot-capture.sh — slice a named excerpt from the rolling ps4-uart log
#
# Usage:
#   boot-capture.sh start <name>   # call BEFORE power-cycling the PS4
#   boot-capture.sh stop <name>    # call AFTER the boot test is done
#
# The pyserial daemon (ps4uart.py) keeps writing one big rolling log
# under ps4-uart/logs/.  This helper records the byte offset at "start"
# and at "stop" extracts that slice into a clean, named file under
# checkpoint/uart-logs/.  Non-printable bytes (from serial reconnects)
# are replaced with '?' so grep/sed work normally.
#
# State is kept in /tmp/boot-capture/<name>.start — survives across
# shells but vanishes on reboot, which is fine for one-shot tests.

set -e

REPO=/home/meerzulee/Work/ps4/linux-ps4
LOGS_DIR=/home/meerzulee/Work/ps4/ps4-uart/logs
OUT_DIR=$REPO/checkpoint/uart-logs
STATE_DIR=/tmp/boot-capture

mkdir -p "$OUT_DIR" "$STATE_DIR"

cmd=${1:-}
name=${2:-}

if [ -z "$cmd" ] || [ -z "$name" ]; then
    cat <<EOF
Usage: $0 {start|stop} <name>

  start <name>   record current byte offset of the active UART log
  stop  <name>   extract bytes from start..now into checkpoint/uart-logs/<name>.log

Example:
  $0 start v7-baikallove
  # ... power-cycle PS4, wait for boot to complete or hang ...
  $0 stop v7-baikallove
EOF
    exit 1
fi

# Sanitize name (replace whitespace and slashes)
SAFE_NAME=$(echo "$name" | tr ' /' '__')

# Find newest UART log file
UART_LOG=$(ls -1t "$LOGS_DIR"/ps4_uart_*.log 2>/dev/null | head -1)
if [ -z "$UART_LOG" ] || [ ! -f "$UART_LOG" ]; then
    echo "ERROR: no rolling UART log found in $LOGS_DIR/"
    exit 1
fi

case "$cmd" in
    start)
        START_BYTES=$(wc -c < "$UART_LOG")
        printf '%s\n%s\n' "$START_BYTES" "$UART_LOG" > "$STATE_DIR/$SAFE_NAME.start"
        echo "[+] Marked start of '$name' at byte $START_BYTES of:"
        echo "    $UART_LOG"
        echo "[+] Power-cycle the PS4 now. When done, run:"
        echo "    $0 stop '$name'"
        ;;
    stop)
        STATE_FILE="$STATE_DIR/$SAFE_NAME.start"
        if [ ! -f "$STATE_FILE" ]; then
            echo "ERROR: no saved start for '$name'. Run '$0 start $name' first."
            exit 1
        fi
        START_BYTES=$(sed -n '1p' "$STATE_FILE")
        SAVED_LOG=$(sed -n '2p' "$STATE_FILE")
        # If the rolling log rotated mid-test, fall back to whatever the daemon writes now
        if [ ! -f "$SAVED_LOG" ]; then
            echo "[!] Saved log path no longer exists, falling back to current rolling log"
            SAVED_LOG=$UART_LOG
        fi
        END_BYTES=$(wc -c < "$SAVED_LOG")
        BYTES=$((END_BYTES - START_BYTES))
        if [ "$BYTES" -le 0 ]; then
            echo "[!] No new bytes since start (END=$END_BYTES, START=$START_BYTES). Did the boot run?"
            exit 1
        fi
        TIMESTAMP=$(date +%Y-%m-%d_%H%M)
        OUT_FILE="$OUT_DIR/$TIMESTAMP-$SAFE_NAME.log"
        # Extract slice by byte offset, sanitize non-printables (keep \n \t)
        tail -c +"$((START_BYTES + 1))" "$SAVED_LOG" \
            | head -c "$BYTES" \
            | tr -c '[:print:]\n\t' '?' \
            > "$OUT_FILE"
        LINES=$(wc -l < "$OUT_FILE")
        SIZE_KB=$(( $(wc -c < "$OUT_FILE") / 1024 ))
        echo "[+] Saved $LINES lines (${SIZE_KB} KB) → $OUT_FILE"
        # Quick automatic summary of interesting signals
        echo ""
        echo "=== quick signal summary ==="
        for PAT in 'Linux version' 'bpcie_create_irq_domain' 'bpcie_init_dev_msi_info' \
                   'bpcie_msi_init' 'bpcie_msi_write_msg' 'bpcie_handle_edge_irq' \
                   'Spurious interrupt' 'Command Aborted' 'Timeout waiting' \
                   'qc timeout' 'WARNING:' 'Kernel panic' 'fence fallback'; do
            # grep -c on a non-matching pattern in the file returns 0 cleanly,
            # but the script-level `|| echo 0` is what produces "0\n0" on a
            # multi-newline file when grep itself returns success.  Use plain
            # grep -c and trust it (errors get "0").
            COUNT=$(grep -c "$PAT" "$OUT_FILE")
            COUNT=${COUNT:-0}
            printf '  %-32s %s\n' "$PAT" "$COUNT"
        done
        rm "$STATE_FILE"
        ;;
    *)
        echo "Unknown command: $cmd  (use 'start' or 'stop')"
        exit 1
        ;;
esac
