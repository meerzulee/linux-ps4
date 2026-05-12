#!/bin/bash
# Richer SBL probe — sweep idx values, watch trigger-clear, watch VAL track input
set -e
REGS=/sys/kernel/debug/dri/0/amdgpu_regs

rd() { sudo dd if=$REGS bs=4 count=1 skip=$(($1/4)) 2>/dev/null | od -An -tx4 | tr -d ' '; }
wr() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($2 & 0xff)) $((($2 >> 8) & 0xff)) $((($2 >> 16) & 0xff)) $((($2 >> 24) & 0xff)))" | sudo dd of=$REGS bs=4 seek=$(($1/4)) 2>/dev/null; }
sir() { wr 0x22000 $1; rd 0x22004; }
siw() { wr 0x22000 $1; wr 0x22004 $2; }

probe_read() {
    local idx=$1
    # Pre-fill mailbox
    wr 0x22070 0xa404         # SMU_READ service id
    wr 0x22074 $idx           # SMU register idx

    # Snapshot before kick
    local v_before=$(rd 0x22078)
    local trig_before=$(sir 0x32)

    # Kick
    siw 0x32 1

    # Poll ack — also try sub-millisecond
    local polls=0
    for i in $(seq 1 200); do
        local ack=$(sir 0x4a)
        if [ $((0x$ack & 1)) -eq 0 ]; then
            polls=$i
            break
        fi
        polls=$i
    done

    local v_after=$(rd 0x22078)
    local status=$(rd 0x2207c)
    local trig_after=$(sir 0x32)
    local ack_final=$(sir 0x4a)

    printf "  idx=%-12s VAL: %s -> %s  STATUS=%s  TRIG: %s -> %s  ACK=%s  polls=%d\n" \
      "0x$(printf '%08x' $idx)" "$v_before" "$v_after" "$status" "$trig_before" "$trig_after" "$ack_final" "$polls"
}

echo "=== sweep: same idx 4 times (should be stable if SAMU is real) ==="
for i in 1 1 1 1 ; do probe_read $i ; done
echo
echo "=== sweep: different idx values ==="
for i in 0 1 2 3 0x10 0xc0080000 0xc0200000 0xdeadbeef ; do probe_read $i ; done
echo
echo "=== current full register snapshot ==="
echo "BAR5 + 0x22070 (CMD)        = $(rd 0x22070)"
echo "BAR5 + 0x22074 (ARG1)       = $(rd 0x22074)"
echo "BAR5 + 0x22078 (VAL)        = $(rd 0x22078)"
echo "BAR5 + 0x2207c (STATUS)     = $(rd 0x2207c)"
echo "SAMU indirect [0x32]        = $(sir 0x32)"
echo "SAMU indirect [0x4a]        = $(sir 0x4a)"
