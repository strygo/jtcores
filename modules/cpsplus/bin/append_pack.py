#!/usr/bin/env python3
"""Append a CPS+ pack to an assembled MRA ROM image (.rom).

Executable form of the delivery spec in INTEGRATION.md §MRA/pack append:

  * the pack is placed at the first 1 kB boundary at/after the end of the
    ROM image (zero padding in between);
  * image bytes 8-9 (a reserved, 0xFF-filled slot of the CPS MRA
    start-pointer header) are patched with the pack offset in 1 kB units,
    little-endian.  0x0000/0xFFFF mean "no pack" to both consumers:
    - jtframe_mister_dwnld.v stops the DDR->core ROM readback at the
      pack offset (patch 0003);
    - cpsplus_ddr reads the same bytes from DDR to find the pack.

Usage:
    append_pack.py game.rom pack.cpk [-o out.rom]

The pack offset is capped at 64 MB - 1 kB by the 16-bit pointer; every
CPS2 ROM image is far below that.  Sanity checks: pack magic, existing
pointer slot must be 0xFFFF or 0x0000 (never overwrite a used slot).
"""
import argparse
import struct
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("rom", type=Path, help="assembled MRA ROM image")
    ap.add_argument("pack", type=Path, help=".cpk pack (PACK_FORMAT.md)")
    ap.add_argument("-o", "--out", type=Path, default=None,
                    help="output (default: <rom>.cpsplus.rom)")
    args = ap.parse_args()

    rom = bytearray(args.rom.read_bytes())
    pack = args.pack.read_bytes()

    if len(rom) < 64:
        sys.exit("ROM image shorter than the 64-byte CPS header")
    if pack[:4] != b"CP2A":
        sys.exit("pack has no CP2A magic")
    slot = struct.unpack_from("<H", rom, 8)[0]
    if slot not in (0x0000, 0xFFFF):
        sys.exit(f"header bytes 8-9 already used (0x{slot:04x})")

    off = (len(rom) + 1023) // 1024 * 1024
    if off >= (1 << 16) * 1024:
        sys.exit("ROM image too large for the 16-bit 1 kB pack pointer")

    rom += b"\0" * (off - len(rom))
    rom += pack
    struct.pack_into("<H", rom, 8, off // 1024)

    out = args.out or args.rom.with_suffix(".cpsplus.rom")
    out.write_bytes(rom)
    print(f"{out}: pack at 0x{off:x} ({off // 1024} kB units -> header "
          f"bytes 8-9), total {len(rom)/1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
