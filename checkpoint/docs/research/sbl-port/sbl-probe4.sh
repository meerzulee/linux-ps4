#!/bin/bash
# SMU WRITE round-trip + status-on-error + wider scan
set -e
REGS=/sys/kernel/debug/dri/0/amdgpu_regs

rd() { sudo dd if=$REGS bs=4 count=1 skip=$(($1/4)) 2>/dev/null | od -An -tx4 | tr -d ' '; }
wr() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($2 & 0xff)) $((($2 >> 8) & 0xff)) $((($2 >> 16) & 0xff)) $((($2 >> 24) & 0xff)))" | sudo dd of=$REGS bs=4 seek=$(($1/4)) 2>/dev/null; }
sir() { wr 0x22000 $1; rd 0x22004; }
siw() { wr 0x22000 $1; wr 0x22004 $2; }

# SBL SMU read
smu_read() {
    local idx=$1
    wr 0x22078 0xdeadbeef
    wr 0x22070 0xa404
    wr 0x22074 $idx
    siw 0x32 1
    sleep 0.001
    echo "$(rd 0x22078)|$(rd 0x2207c)"  # val|status
}
# SBL SMU write
smu_write() {
    local idx=$1
    local val=$2
    wr 0x22070 0xa505
    wr 0x22074 $idx
    wr 0x22078 $val
    siw 0x32 1
    sleep 0.001
    echo "$(rd 0x2207c)"  # status
}

echo "=== ROUND-TRIP TEST: read, write, read back ==="
for idx in 0x10 0x20 0x200 0x800 0xc0200000 0xc0300000 0xc0500000 ; do
    r1=$(smu_read $idx)
    val1=${r1%|*}
    s_write=$(smu_write $idx 0xcafe1234)
    r2=$(smu_read $idx)
    val2=${r2%|*}
    if [ "$val1" = "$val2" ]; then
        rt="UNCHANGED (write rejected or RO)"
    elif [ "$val2" = "cafe1234" ]; then
        rt="ACCEPTED WRITE!"
    else
        rt="WROTE-AND-SOMETHING-CHANGED ($val1 -> $val2)"
    fi
    printf "  idx=$(printf '0x%08x' $idx)  read1=0x%s  write_status=0x%s  read2=0x%s  %s\n" "$val1" "$s_write" "$val2" "$rt"
done

echo
echo "=== STATUS-ON-ERROR: clearly invalid idx values ==="
for idx in 0x7fffffff 0xffffffff 0xa5a5a5a5 0x80000000 0xeeeeeeee ; do
    r=$(smu_read $idx)
    val=${r%|*}
    status=${r#*|}
    printf "  idx=$(printf '0x%08x' $idx)  val=0x%s  status=0x%s\n" "$val" "$status"
done

echo
echo "=== WIDER SCAN: sweep 0xC0000000 + 0xC0500000 banks in detail ==="
echo "  -- bank 0xC0000000 (offsets 0..0x300 step 4) --"
for off in $(seq 0 4 0x100) ; do
    addr=$((0xc0000000 + off))
    r=$(smu_read $addr)
    val=${r%|*}
    if [ "$val" != "00000000" ] && [ "$val" != "deadbeef" ]; then
        printf "    [0x%08x] = 0x%s\n" $addr "$val"
    fi
done

echo "  -- bank 0xC0500000 (offsets 0..0x300 step 4) --"
for off in $(seq 0 4 0x100) ; do
    addr=$((0xc0500000 + off))
    r=$(smu_read $addr)
    val=${r%|*}
    if [ "$val" != "00000000" ] && [ "$val" != "deadbeef" ]; then
        printf "    [0x%08x] = 0x%s\n" $addr "$val"
    fi
done

echo
echo "=== Sony-specific banks (less mainline) ==="
# Sony might use custom bank numbers — try the higher ranges
for base in 0xc0b00000 0xc0c00000 0xc0d00000 0xc0e00000 0xc0f00000 \
            0xc1000000 0xc1100000 0xc1200000 0xc1300000 0xc1400000 \
            0xc1500000 0xc2000000 0xc4000000 0xc8000000 ; do
    r=$(smu_read $base)
    val=${r%|*}
    status=${r#*|}
    if [ "$val" != "00000000" ] && [ "$val" != "deadbeef" ]; then
        printf "  [%s] = 0x%s  status=0x%s\n" $(printf '0x%08x' $base) "$val" "$status"
    fi
done
