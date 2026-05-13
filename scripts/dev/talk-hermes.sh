#!/usr/bin/env bash
# talk-hermes.sh — send a single-message dispatch to hermes without
# triggering the "new message" interrupt-per-chunk behavior that
# talk.sh's 500-char chunking causes in hermes' TUI.
#
# Usage:
#   talk-hermes.sh "single short message"
#   talk-hermes.sh < /tmp/brief.txt
#
# Compared to scripts/dev/talk.sh:
#   - One write-chars call (no chunking).  zellij action write-chars
#     accepts up to ~16 KB in one call.
#   - 1.0s settle pause before pressing Enter so the TUI's input box
#     finishes ingesting the whole message before submit.
#   - Uses `--` separator (talk.sh fix from earlier).
#
# To peek hermes, use the existing `talk.sh peek hermes [lines]`.

set -e

PANE=terminal_2  # hermes

if [[ $# -ge 1 ]]; then
    MSG="$*"
else
    MSG="$(cat)"
fi

if [[ -z "$MSG" ]]; then
    echo "[!] no message" >&2
    exit 2
fi

MSG_LEN=${#MSG}

# zellij action write-chars has a CLI arg-length limit (~128 KB on most
# Linux systems, set by ARG_MAX).  We're well under that for any
# reasonable agent brief.  Send in one shot.
self_pane="${ZELLIJ_PANE_ID:-terminal_0}"
case "$self_pane" in
    [0-9]*) self_pane="terminal_$self_pane" ;;
esac

zellij action focus-pane-id "$PANE" >/dev/null
sleep 0.5
zellij action write-chars -- "$MSG" >/dev/null

# Give the TUI input box time to fully ingest the message before Enter.
# 1s is generous but reliable — without this hermes occasionally fires
# Enter on a partial buffer.
sleep 1.0
zellij action send-keys 'Enter' >/dev/null
sleep 0.3
zellij action focus-pane-id "$self_pane" >/dev/null
echo "[+] sent $MSG_LEN chars to hermes ($PANE)"
