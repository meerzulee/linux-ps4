#!/usr/bin/env python3
"""Probe both PS4 BPCIe UART MMIO regions, looking for the one connected
to the user's physical UART cable.

UART0 = BAR2 + 0x10E000 = 0xC890E000
UART1 = BAR2 + 0x10F000 = 0xC890F000

Each UART is 8250-compat with regshift=2 → register N is at byte offset N*4.
LSR (Line Status Register) is reg 5 → byte offset 0x14.
THR (Transmit Holding Reg, write only) is reg 0 → byte offset 0x00.

We read LSR on both (THRE bit 5 should be 1 if hardware is alive),
then write a sentinel pattern to each TX. Watch the physical UART
terminal — whichever pattern arrives is the one with the cable.
"""
import os
import mmap
import struct
import time
import sys

PAGE = 4096


def _mmap(phys: int, prot: int):
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    base = phys & ~(PAGE - 1)
    off = phys - base
    m = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, prot, offset=base)
    return fd, m, off


def read_u32(phys: int) -> int:
    fd, m, off = _mmap(phys, mmap.PROT_READ)
    v = struct.unpack("<I", m[off:off + 4])[0]
    m.close()
    os.close(fd)
    return v


def write_u32(phys: int, val: int):
    fd, m, off = _mmap(phys, mmap.PROT_READ | mmap.PROT_WRITE)
    m[off:off + 4] = struct.pack("<I", val)
    m.close()
    os.close(fd)


def write_chars(base: int, data: bytes, label: str):
    print(f"{label}: writing {data!r} to 0x{base:x}")
    for c in data:
        # Wait for THRE
        for _ in range(1000):
            lsr = read_u32(base + 0x14)
            if lsr & (1 << 5):
                break
            time.sleep(0.0005)
        write_u32(base + 0x00, c)


for name, base in [("UART0", 0xC890E000), ("UART1", 0xC890F000)]:
    lsr = read_u32(base + 0x14)
    thre = (lsr >> 5) & 1
    temt = (lsr >> 6) & 1
    print(f"{name} @ 0x{base:08x}: LSR=0x{lsr:08x}  THRE={thre} TEMT={temt}")

# Three-second pause so user can spot the markers in the live tail.
time.sleep(0.5)
write_chars(0xC890E000, b"AAAA-UART0\n", "UART0")
time.sleep(0.5)
write_chars(0xC890F000, b"BBBB-UART1\n", "UART1")
time.sleep(0.5)

print("done")
