#!/bin/bash
# Sentinel + bit-walk SAMU characterization.
set -e
REGS=/sys/kernel/debug/dri/0/amdgpu_regs

rd() { sudo dd if=$REGS bs=4 count=1 skip=$(($1/4)) 2>/dev/null | od -An -tx4 | tr -d ' '; }
wr() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($2 & 0xff)) $((($2 >> 8) & 0xff)) $((($2 >> 16) & 0xff)) $((($2 >> 24) & 0xff)))" | sudo dd of=$REGS bs=4 seek=$(($1/4)) 2>/dev/null; }
sir() { wr 0x22000 $1; rd 0x22004; }
siw() { wr 0x22000 $1; wr 0x22004 $2; }

# trigger a SAMU SMU_READ and return whether VAL changed from sentinel.
# Writes sentinel BEFORE the trigger so we can see overwrite.
test_read() {
    local idx=$1
    local sentinel=0xdeadbeef
    wr 0x22078 $sentinel       # set sentinel directly in VAL
    wr 0x22070 0xa404          # CMD = SMU_READ
    wr 0x22074 $idx
    siw 0x32 1                 # trigger
    # tiny pause to let SAMU do its thing
    sleep 0.001
    local v=$(rd 0x22078)
    local s=$(rd 0x2207c)
    if [ "$v" = "deadbeef" ]; then
        echo "  idx=$(printf '0x%08x' $idx)  VAL=UNCHANGED (sentinel kept)  STATUS=$s"
    else
        echo "  idx=$(printf '0x%08x' $idx)  VAL=0x$v  STATUS=$s"
    fi
}

echo "=== SENTINEL TEST 1: low idx values ==="
for i in 0 1 2 3 4 5 8 0x10 0x20 0x40 0x80 0x100 0x200 0x400 0x800 0x1000 ; do
    test_read $i
done

echo
echo "=== SENTINEL TEST 2: CIK SMU register banks ==="
# Mainline CIK SMU register convention: 0xC0XX_XXXX with the upper bits selecting block
for base in 0xc0000000 0xc0080000 0xc0100000 0xc0200000 0xc0300000 0xc0400000 0xc0500000 0xc0600000 0xc0700000 0xc0800000 0xc0900000 0xc0a00000 ; do
    for off in 0 0x10 0x20 0x40 0x100 0x200 ; do
        addr=$((base + off))
        test_read $addr
    done
done

echo
echo "=== BIT-WALK on SAMU[0x32] (trigger reg) ==="
# Read current value, then write each bit individually, then read back.
# Skip bit 0 (we don't want to spuriously trigger). Concentrate on 1..31.
orig=$(sir 0x32)
echo "  baseline SAMU[0x32] = 0x$orig"
for bit in 1 2 3 4 8 16 24 31 ; do
    val=$((1 << bit))
    siw 0x32 $val
    after=$(sir 0x32)
    printf "  wrote bit %d (val=0x%08x) -> reads back 0x%s\n" $bit $val $after
done
# restore
siw 0x32 $((0x$orig))

echo
echo "=== BIT-WALK on SAMU[0x4a] (ack reg) ==="
orig=$(sir 0x4a)
echo "  baseline SAMU[0x4a] = 0x$orig"
for bit in 0 1 2 3 4 8 16 24 31 ; do
    val=$((1 << bit))
    siw 0x4a $val
    after=$(sir 0x4a)
    printf "  wrote bit %d (val=0x%08x) -> reads back 0x%s\n" $bit $val $after
done

echo
echo "=== TIGHT BURST: 100 triggers, look for ack-bit flicker ==="
seen_ack_set=0
for i in $(seq 1 100); do
    wr 0x22070 0xa404
    wr 0x22074 0x10
    siw 0x32 1
    ack=$(sir 0x4a)
    if [ $((0x$ack & 1)) -ne 0 ]; then
        seen_ack_set=$((seen_ack_set + 1))
        echo "    iter $i: ack=0x$ack"
    fi
done
echo "  ack-bit-0-set observed in $seen_ack_set of 100 polls"
