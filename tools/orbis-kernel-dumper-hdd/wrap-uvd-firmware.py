#!/usr/bin/env python3
"""
wrap-uvd-firmware.py — wrap Sony's raw UVD ucode in an AMDGPU
common_firmware_header so Linux's mainline amdgpu_uvd_sw_init can load it.

Why this exists
---------------
Sony's PS4 kernel embeds the UVD firmware as a raw ucode blob with no
header — they just memcpy it into VRAM. Mainline AMDGPU, however,
requires the firmware file to start with a `common_firmware_header`
(struct in drivers/gpu/drm/amd/amdgpu/amdgpu_ucode.h):

    uint32_t size_bytes;             // total file size = header + padding + ucode
    uint32_t header_size_bytes;      // sizeof(common_firmware_header) = 0x20
    uint16_t header_version_major;   // 1
    uint16_t header_version_minor;   // 0
    uint16_t ip_version_major;       // 4  (UVD 4.2 on Bonaire/Liverpool)
    uint16_t ip_version_minor;       // 2
    uint32_t ucode_version;          // packed (major<<24)|(rev<<16)|(minor<<8)|family_id
    uint32_t ucode_size_bytes;       // size of ucode payload
    uint32_t ucode_array_offset_bytes; // typically 0x100 (header + 224 zero bytes)
    uint32_t crc32;                  // zlib.crc32 of the ucode payload

Mainline `amdgpu_uvd_sw_init` (amdgpu_uvd.c:274-296 in our 6.x tree) does:

    hdr = (struct common_firmware_header *)fw->data;
    family_id     = ucode_version & 0xff;        # bits 0..7
    version_minor = (ucode_version >> 8) & 0xff; # bits 8..15
    version_major = (ucode_version >> 24) & 0xff;# bits 24..31
    DRM_INFO("Found UVD firmware Version: %u.%u Family ID: %u\\n", ...);

Notice: bits 16..23 are not used by the version-decode path — they
hold the ucode "revision" / patch level for our own bookkeeping.

How to use
----------
    ./wrap-uvd-firmware.py \\
        --in  checkpoint/docs/research/orbis-kernel/liverpool_uvd_baikal.bin \\
        --out checkpoint/docs/research/orbis-kernel/liverpool_uvd_wrapped.bin \\
        --version 1.101.42 \\
        --family-id 9

The --version triple comes from the banner string Sony embeds right
before the firmware blob inside their kernel:

    [ATI LIB=UVDFW,1.101.42]  ← for Late Liverpool / Baikal at 0xc8c67f70

--family-id should be 9 for UVD on the Bonaire-class chip family
(matches the firmware our existing initramfs ships, version 1.64).
"""

from __future__ import annotations
import argparse, struct, sys, zlib
from pathlib import Path


def parse_version(v: str) -> tuple[int, int, int]:
    """'1.101.42' -> (1, 101, 42).  Each part must fit in one byte."""
    parts = v.split('.')
    if len(parts) != 3:
        raise ValueError(f"--version must be major.minor.revision (got {v!r})")
    major, minor, rev = (int(p, 0) for p in parts)
    for name, val in (('major', major), ('minor', minor), ('revision', rev)):
        if not 0 <= val <= 0xff:
            raise ValueError(f"--version {name} {val} out of byte range 0..255")
    return major, minor, rev


def pack_ucode_version(major: int, minor: int, rev: int, family_id: int) -> int:
    return ((major & 0xff) << 24) | ((rev & 0xff) << 16) | ((minor & 0xff) << 8) | (family_id & 0xff)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument('--in',  dest='inp', required=True, type=Path,
                    help='Sony raw ucode blob (extracted from kernel.elf)')
    ap.add_argument('--out', dest='outp', required=True, type=Path,
                    help='wrapped firmware to write (drop into '
                         '/lib/firmware/amdgpu/liverpool_uvd.bin)')
    ap.add_argument('--version', required=True,
                    help='major.minor.revision triple (e.g. 1.101.42)')
    ap.add_argument('--family-id', type=lambda s: int(s, 0), default=9,
                    help='AMDGPU UVD family-id byte (default 9 = Bonaire-class)')
    ap.add_argument('--header-pad', type=lambda s: int(s, 0), default=0x100,
                    help='offset where ucode body starts (default 0x100, '
                         'matches mainline UVD reference firmware layout)')
    ap.add_argument('--ip-version', default='4.2',
                    help='IP version major.minor (default 4.2 for UVD 4.2)')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    major, minor, rev = parse_version(args.version)
    ucode_version = pack_ucode_version(major, minor, rev, args.family_id)

    ip_maj_s, _, ip_min_s = args.ip_version.partition('.')
    ip_major, ip_minor = int(ip_maj_s), int(ip_min_s)

    ucode = args.inp.read_bytes()
    ucode_size = len(ucode)
    ucode_offset = args.header_pad
    total_size = ucode_offset + ucode_size
    crc = zlib.crc32(ucode) & 0xffffffff

    header = struct.pack('<IIHHHHIIII',
        total_size,        # size_bytes
        0x20,              # header_size_bytes
        1, 0,              # header_version_major.minor
        ip_major, ip_minor, # ip_version_major.minor
        ucode_version,     # packed (major.minor.rev + family_id)
        ucode_size,        # ucode_size_bytes
        ucode_offset,      # ucode_array_offset_bytes
        crc,               # crc32(ucode body)
    )
    assert len(header) == 0x20

    padding = b'\x00' * (ucode_offset - len(header))
    args.outp.write_bytes(header + padding + ucode)

    if not args.quiet:
        print(f"wrote {args.outp}")
        print(f"  total_size       = 0x{total_size:08x} ({total_size})")
        print(f"  ucode_size       = 0x{ucode_size:08x} ({ucode_size})")
        print(f"  ucode_array_off  = 0x{ucode_offset:08x}")
        print(f"  ucode_version    = 0x{ucode_version:08x}")
        print(f"  -> mainline will report: Found UVD firmware Version: "
              f"{major}.{minor} Family ID: {args.family_id}")
        print(f"  -> our rev byte (for own use): {rev} (0x{rev:02x})")
        print(f"  crc32(body)      = 0x{crc:08x}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
