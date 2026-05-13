#!/usr/bin/env bash
# talk.sh — send a message to another zellij pane (an AI agent coworker).
# Usage:
#   talk.sh <pane-or-agent> <message...>
#   talk.sh peek <pane-or-agent> [lines]    # dump tail of their screen
#   talk.sh peekfull <pane-or-agent>        # dump with scrollback
#   talk.sh list                            # show known panes
#
# pane-or-agent: hermes | glm | kimi | deepseek | terminal_N
set -euo pipefail

resolve_pane() {
    case "$1" in
        hermes)   echo terminal_2 ;;
        glm)      echo terminal_8 ;;
        kimi)     echo terminal_9 ;;
        deepseek) echo terminal_10 ;;
        terminal_*) echo "$1" ;;
        *)
            echo "unknown agent/pane: $1" >&2
            echo "known: hermes glm kimi deepseek terminal_N" >&2
            exit 2
            ;;
    esac
}

cmd="${1:-}"
shift || true

case "$cmd" in
    list)
        zellij action list-panes
        ;;
    peek)
        agent="${1:?usage: talk.sh peek <agent> [lines]}"
        lines="${2:-30}"
        pane="$(resolve_pane "$agent")"
        zellij action dump-screen -p "$pane" | tail -n "$lines"
        ;;
    peekfull)
        agent="${1:?usage: talk.sh peekfull <agent>}"
        pane="$(resolve_pane "$agent")"
        zellij action dump-screen -p "$pane" --full
        ;;
    *)
        agent="$cmd"
        msg="$*"
        if [[ -z "$agent" || -z "$msg" ]]; then
            echo "usage: talk.sh <agent> <message>" >&2
            echo "       talk.sh peek <agent> [lines]" >&2
            echo "       talk.sh peekfull <agent>" >&2
            echo "       talk.sh list" >&2
            exit 2
        fi
        pane="$(resolve_pane "$agent")"
        self_pane="${ZELLIJ_PANE_ID:-terminal_0}"
        # Some zellij versions print pane id as "0" not "terminal_0"; normalize.
        case "$self_pane" in
            [0-9]*) self_pane="terminal_$self_pane" ;;
        esac

        zellij action focus-pane-id "$pane" >/dev/null
        sleep 0.5

        # write-chars in chunks so a single large message doesn't get
        # cut by zellij/terminal buffer.  500-char chunks with small
        # delay between to give the agent TUI input box time to
        # accept the chars.  Without this, long prompts have been
        # observed to land partly on the underlying fish prompt
        # (causing "fish: Unknown command: =" etc).
        msg_len=${#msg}
        idx=0
        chunk=500
        while [ "$idx" -lt "$msg_len" ]; do
            piece="${msg:$idx:$chunk}"
            zellij action write-chars "$piece" >/dev/null
            sleep 0.15
            idx=$((idx + chunk))
        done

        sleep 0.4
        zellij action send-keys 'Enter' >/dev/null
        sleep 0.3
        zellij action focus-pane-id "$self_pane" >/dev/null
        echo "sent -> $agent ($pane)"
        ;;
esac
