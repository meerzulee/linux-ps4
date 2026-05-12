#!/bin/bash
# Direct SBL protocol probe via /sys/kernel/debug/dri/0/amdgpu_regs.
# Doesn't need our ps4_sbl module — uses mainline amdgpu's register file directly.
set -e
REGS=/sys/kernel/debug/dri/0/amdgpu_regs

# rd(byte_off) -> hex value as 0xXXXXXXXX
rd() {
    sudo dd if=$REGS bs=4 count=1 skip=$(( $1 / 4 )) 2>/dev/null | od -An -tx4 | tr -d ' '
}
# wr(byte_off, val) -> write 32-bit val
wr() {
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( $2 & 0xff )) $(( ($2 >> 8) & 0xff )) $(( ($2 >> 16) & 0xff )) $(( ($2 >> 24) & 0xff )))" \
      | sudo dd of=$REGS bs=4 seek=$(( $1 / 4 )) 2>/dev/null
}
# samu_ind_read(idx) - write idx -> 0x22000, return 0x22004
sir() { wr 0x22000 $1 ; rd 0x22004 ; }
# samu_ind_write(idx, val)
siw() { wr 0x22000 $1 ; wr 0x22004 $2 ; }

echo "=== baseline (no probe yet) ==="
echo "BAR5 + 0x22070 (CMD)         = $(rd 0x22070)"
echo "BAR5 + 0x22074 (ARG1)        = $(rd 0x22074)"
echo "BAR5 + 0x22078 (VAL)         = $(rd 0x22078)"
echo "BAR5 + 0x2207c (STATUS)      = $(rd 0x2207c)"
echo "BAR5 + 0x22000 (IND_INDEX)   = $(rd 0x22000)"
echo "BAR5 + 0x22004 (IND_DATA)    = $(rd 0x22004)"
echo "SAMU indirect [0x32] (TRIG)  = $(sir 0x32)"
echo "SAMU indirect [0x4a] (ACK)   = $(sir 0x4a)"
echo
echo "=== issuing READ idx=1 via proper Sony sequence ==="
wr 0x22070 0xa404          # service id = SMU_READ
wr 0x22074 0x00000001      # SMU register index = 1
siw 0x32 1                 # SAMU[0x32] <- 1 (trigger!)

echo "  immediately after trigger:"
echo "  SAMU[0x4a] (ACK) = $(sir 0x4a)"

# poll for up to 1 second
for i in $(seq 1 50); do
    ack=$(sir 0x4a)
    val=$(( 0x$ack ))
    if [ $((val & 1)) -eq 0 ]; then
        echo "  acked after $i polls (~$((i * 20))ms)"
        break
    fi
    sleep 0.02
done

echo
echo "=== post-trigger state ==="
echo "BAR5 + 0x22078 (VAL)        = $(rd 0x22078)"
echo "BAR5 + 0x2207c (STATUS)     = $(rd 0x2207c)"
echo "SAMU indirect [0x32] (TRIG) = $(sir 0x32)"
echo "SAMU indirect [0x4a] (ACK)  = $(sir 0x4a)"
