#!/bin/bash
# Probe 5: explore alternative service IDs + SAMU control reg space + 0xc2 bank
set -e
REGS=/sys/kernel/debug/dri/0/amdgpu_regs

rd() { sudo dd if=$REGS bs=4 count=1 skip=$(($1/4)) 2>/dev/null | od -An -tx4 | tr -d ' '; }
wr() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($2 & 0xff)) $((($2 >> 8) & 0xff)) $((($2 >> 16) & 0xff)) $((($2 >> 24) & 0xff)))" | sudo dd of=$REGS bs=4 seek=$(($1/4)) 2>/dev/null; }
sir() { wr 0x22000 $1; rd 0x22004; }
siw() { wr 0x22000 $1; wr 0x22004 $2; }

# Issue a SBL command with arbitrary service id
sbl_cmd() {
    local svc=$1
    local arg=$2
    local val=$3
    wr 0x22078 0xdeadbeef
    wr 0x22070 $svc
    wr 0x22074 $arg
    [ -n "$val" ] && wr 0x22078 $val
    siw 0x32 1
    sleep 0.001
    echo "$(rd 0x22078)|$(rd 0x2207c)"
}

echo "=== Service-ID sweep (find what else SAMU answers) ==="
for svc in 0xa000 0xa001 0xa100 0xa200 0xa300 0xa400 0xa401 0xa402 0xa403 0xa404 0xa405 \
           0xa500 0xa501 0xa502 0xa503 0xa504 0xa505 0xa506 0xa600 0xa700 0xa800 0xa900 \
           0xaa00 0xab00 0xac00 0xad00 0xae00 0xaf00 0xb000 0x1 0x2 0x3 0x4 0x5 ; do
    r=$(sbl_cmd $svc 0x10 0xcafe1234)
    val=${r%|*}
    status=${r#*|}
    if [ "$status" != "00000000" ] || [ "$val" != "deadbeef" ] ; then
        printf "  svc=$(printf '0x%04x' $svc)  val=0x%s  status=0x%s\n" "$val" "$status"
    fi
done

echo
echo "=== Scan 0xc2000000 bank ==="
for off in 0 0x4 0x8 0xc 0x10 0x14 0x18 0x1c 0x20 0x40 0x100 0x200 ; do
    addr=$((0xc2000000 + off))
    r=$(sbl_cmd 0xa404 $addr)
    val=${r%|*}
    status=${r#*|}
    if [ "$val" != "deadbeef" ] && [ "$val" != "00000000" ] ; then
        printf "  [0x%08x] = 0x%s  (status=0x%s)\n" $addr "$val" "$status"
    fi
done

echo
echo "=== SAMU indirect reg sweep [0..0x80] (find more control regs near 0x32/0x4a) ==="
for idx in $(seq 0 0x80) ; do
    val=$(sir $idx)
    if [ "$val" != "00000000" ] ; then
        printf "  SAMU[0x%02x] = 0x%s\n" $idx "$val"
    fi
done

echo
echo "=== Probe SAMU regs near 0x32/0x4a ==="
for idx in 0x30 0x31 0x32 0x33 0x34 0x40 0x45 0x48 0x49 0x4a 0x4b 0x4c 0x4d 0x50 0x60 0x70 ; do
    val=$(sir $idx)
    printf "  SAMU[0x%02x] = 0x%s\n" $idx "$val"
done
