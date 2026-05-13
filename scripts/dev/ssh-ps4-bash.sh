#!/usr/bin/env bash
# ssh-ps4-bash.sh — run a command on PS4 via bash (not fish).
#
# PS4's user login shell is /usr/bin/fish.  When ssh executes a remote
# command, it goes through fish which chokes on bash-style syntax like
# `v=$(...)`, `for v in 0x4 0x6;`, `cmd1 && cmd2`.
#
# Usage: ssh-ps4-bash.sh '<bash commands>'
# All args are concatenated with spaces and passed to bash -c on the PS4.
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "usage: $0 '<bash commands>'" >&2
    exit 2
fi

# Concatenate all args into one bash script
script="$*"

# Quote-safe wrapping for ssh: use a HEREDOC-style passthrough via stdin
exec ssh ps4 bash -s <<EOF
$script
EOF
