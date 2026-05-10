#!/usr/bin/env python3
"""
sky2-probe: poke the Baikal GbE BAR0 directly from userspace.

Goal: figure out why sky2_init's `sky2_read8(hw, B2_CHIP_ID=0x011b)` returns 0
on Baikal. Needs to be run as root, with the sky2 driver NOT currently bound
(it isn't on Baikal because probe fails with -EOPNOTSUPP).
"""
import argparse
import mmap
import os
import struct
import sys
import time

PCI = "/sys/bus/pci/devices/0000:00:14.1"
BAR0 = f"{PCI}/resource0"
BAR_SIZE = 4096

# sky2 register offsets (from sky2.h)
B0_CTST       = 0x004
B0_LED        = 0x005
B0_CTST_HI    = 0x006
B0_PWR_CTRL   = 0x007
B2_CHIP_ID    = 0x011b
B2_MAC_CFG    = 0x011c
B2_PMD_TYP    = 0x011d
B2_MAC_1      = 0x0100  # MAC address
PCI_DEV_REG3  = 0x80    # config space, but mirrored in BAR

# Reset bits
CS_RST_SET    = 0x01
CS_RST_CLR    = 0x02

def open_bar():
    fd = os.open(BAR0, os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, BAR_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
    return mm

def r8(mm, off):  return mm[off]
def r16(mm, off): return struct.unpack('<H', mm[off:off+2])[0]
def r32(mm, off): return struct.unpack('<I', mm[off:off+4])[0]
def w32(mm, off, val): mm[off:off+4] = struct.pack('<I', val); os.fsync(0)
def w16(mm, off, val): mm[off:off+2] = struct.pack('<H', val); os.fsync(0)
def w8(mm, off, val):  mm[off:off+1] = bytes([val & 0xff]); os.fsync(0)

def dump_baseline(mm, label):
    print(f"\n=== {label} ===")
    print(f"  B0_CTST    (0x004): 0x{r8(mm, B0_CTST):02x}")
    print(f"  B2_CHIP_ID (0x11b): 0x{r8(mm, B2_CHIP_ID):02x}")
    print(f"  B2_MAC_CFG (0x11c): 0x{r8(mm, B2_MAC_CFG):02x}")
    print(f"  B2_PMD_TYP (0x11d): 0x{r8(mm, B2_PMD_TYP):02x}")
    # Dump first 16 dwords
    print("  First 64 bytes:")
    for off in range(0, 64, 16):
        ws = [f"{r32(mm, off+i):08x}" for i in (0, 4, 8, 12)]
        print(f"    [0x{off:04x}] {' '.join(ws)}")
    # Dump 0x100..0x180 (chip-id area + nearby)
    print("  Chip-ID region (0x100..0x180):")
    for off in range(0x100, 0x180, 16):
        ws = [f"{r32(mm, off+i):08x}" for i in (0, 4, 8, 12)]
        print(f"    [0x{off:04x}] {' '.join(ws)}")

def find_nonzero(mm, start=0, end=BAR_SIZE):
    """Scan for any non-zero 32-bit word."""
    out = []
    for off in range(start, end, 4):
        v = r32(mm, off)
        if v != 0:
            out.append((off, v))
    return out

def main():
    p = argparse.ArgumentParser()
    p.add_argument('cmd', nargs='?', default='dump',
                   choices=['dump', 'aeolia-init', 'reset', 'scan-nonzero', 'compare'])
    args = p.parse_args()

    mm = open_bar()
    try:
        if args.cmd == 'dump':
            dump_baseline(mm, "BAR0 dump (no init)")

        elif args.cmd == 'scan-nonzero':
            print("Scanning entire BAR0 for non-zero u32...")
            nz = find_nonzero(mm)
            print(f"Found {len(nz)} non-zero u32:")
            for off, v in nz[:64]:
                print(f"  [0x{off:04x}] 0x{v:08x}")
            if len(nz) > 64:
                print(f"  ... and {len(nz)-64} more")

        elif args.cmd == 'reset':
            print("Trying CS_RST_CLR (sky2_init prep)...")
            print(f"  B0_CTST before: 0x{r8(mm, B0_CTST):02x}")
            w8(mm, B0_CTST, CS_RST_CLR)
            time.sleep(0.01)
            print(f"  B0_CTST after:  0x{r8(mm, B0_CTST):02x}")
            print(f"  B2_CHIP_ID after: 0x{r8(mm, B2_CHIP_ID):02x}")

        elif args.cmd == 'aeolia-init':
            dump_baseline(mm, "BEFORE Aeolia init")
            print("\n>> Applying Aeolia init magic...")
            w32(mm, 0x60, 0x32100)
            w32(mm, 0x64, 0x6)
            w32(mm, 0x68, 0x63b9c)
            w32(mm, 0x6c, 0x300)
            v1 = r32(mm, 0x158)
            v2 = r32(mm, 0x160)
            print(f"   pre 0x158=0x{v1:08x}  0x160=0x{v2:08x}")
            w32(mm, 0x158, v1 & ~0x33333333)
            w32(mm, 0x160, v2 & ~0x0CC00000)
            time.sleep(0.05)
            print(">> Now CS_RST_CLR + read chip_id...")
            w8(mm, B0_CTST, CS_RST_CLR)
            time.sleep(0.05)
            dump_baseline(mm, "AFTER Aeolia init + reset_clr")

        elif args.cmd == 'compare':
            print("Compare scan vs known Yukon-2 register signature.")
            print(f"  B0_CTST=0x{r8(mm,B0_CTST):02x} (expected: bit0/1 reset state)")
            print(f"  B2_CHIP_ID=0x{r8(mm,B2_CHIP_ID):02x} (expected: 0xb3-0xbb for Yukon-2)")
            # Read MAC if there
            mac_bytes = bytes(mm[0x100:0x106])
            print(f"  Bytes at 0x100..0x105: {mac_bytes.hex(':')}")

    finally:
        mm.close()

if __name__ == '__main__':
    main()
