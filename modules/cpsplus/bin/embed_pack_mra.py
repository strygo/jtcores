#!/usr/bin/env python3
"""Embed a CPS+ pack into a jtCPS2/jtCPS1.5 MRA — the MiSTer-native delivery.

An MRA is declarative XML: the MiSTer loader concatenates the <part>s under
<rom index="0"> (in order, applying interleave/byte-swap) into one flat image
and DMAs it to the core.  For CPS jtcores that image lands in DDR at
0x30000000 and persists (research jtcps2_core_analysis §4).  So a pack is
delivered by APPENDING it to that same <rom index="0"> node:

  1. a zero <part> that pads the assembled ROM to the next 1 kB boundary,
  2. the pack file itself as a final <part name="game.cpk">,
  3. a <patch offset="8"> that writes the pack's 1 kB-unit offset (LE u16)
     into image header bytes 8-9 — the reserved CPS start-pointer slot both
     consumers read (jtframe_mister_dwnld clamp + cpsplus_ddr base_indirect).

This is the INTEGRATION.md §MRA-native path.  It keeps packs installable
with stock MiSTer tooling (no ARM changes).  The pack .cpk must be placed in
the ROM zip alongside the arcade ROMs, OR referenced by an absolute-path
<part> — MiSTer supports both; we emit the zip-relative form by default.

This tool does NOT author the arcade region layout — it transforms an
already-correct jtCPS2 MRA (from the jtcores build output, a jotego release,
or your own translation workflow).  It computes the assembled ROM length by
summing the existing <part> byte lengths so the pad is exact; supply --rom-len
to override when parts reference files this tool can't measure.

Usage:
  embed_pack_mra.py base.mra game.cpk --zip-name game.cpk [-o out.mra]
  embed_pack_mra.py base.mra game.cpk --rom-len 0xC00000 -o out.mra

Self-test (no external files):
  embed_pack_mra.py --self-test
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

KB = 1024
POINTER_OFFSET = 8          # header bytes 8-9, LE u16, 1 kB units
MAGIC = b"CP2A"


def measure_header_len(rom_node):
    """Bytes of the LEADING inline <part>s — the jtframe MRA header.

    A jtcores MRA image starts with a small inline header (64 B on CPS1, 44 B
    on CPS2) whose bytes 8-9 are the reserved pack-pointer slot we patch.  The
    region comments ("maincpu - starts at 0x0 …") and the "Total 0x… bytes"
    comment that --rom-len is taken from are measured AFTER that header, so the
    header must be added to get the true assembled image length.

    Getting this wrong put every pack `header` bytes past where its pointer
    claimed: the loader read short, found no CP2A, and failed open to arcade
    audio on all three cores (measured on MiSTer 2026-07-27, DBG status 5).
    """
    total = 0
    for el in list(rom_node):
        if el.tag == "interleave" or (el.tag == "part" and el.get("name")):
            break                      # first file-backed part ends the header
        if el.tag == "part" and not el.get("name"):
            text = (el.text or "").strip()
            if not text:
                continue
            nbytes = len(bytes.fromhex(text.replace(" ", "").replace("\n", "")))
            total += nbytes * int(el.get("repeat", "1"), 0)
    return total


def measure_rom_len(rom_node):
    """Sum byte lengths of the existing index-0 parts (best effort).

    Handles inline hex <part>ABCD</part> and <part repeat=N>00</part> pads.
    File-backed <part name="x.rom"/> cannot be measured here — the caller
    must pass --rom-len for those (jtcps2 arcade parts are file-backed, so
    --rom-len from the build's assembled image is the normal path).
    """
    total = 0
    measurable = True
    for part in rom_node.findall("part"):
        if part.get("name") is not None:
            measurable = False
            continue
        text = (part.text or "").strip()
        if not text:
            continue
        nbytes = len(bytes.fromhex(text.replace(" ", "").replace("\n", "")))
        total += nbytes * int(part.get("repeat", "1"), 0)   # repeat may be hex
    return total, measurable


def embed(base_mra: str, pack_len: int, pack_zip_name: str, rom_len: int | None,
          pack_zip: str | None = None, display_name: str | None = None,
          rbf: str | None = None):
    tree = ET.parse(base_mra)
    root = tree.getroot()
    if display_name is not None:
        nm = root.find("name")
        if nm is None:
            nm = ET.SubElement(root, "name")
        nm.text = display_name
    # Bind the MRA to the CPS+ core so MiSTer loads jtcps2_cpsplus (which can
    # read the appended pack), not stock jtcps2 which would ignore it.
    if rbf is not None:
        rb = root.find("rbf")
        if rb is None:
            rb = ET.SubElement(root, "rbf")
        rb.text = rbf
    rom = None
    for r in root.findall("rom"):
        if r.get("index") == "0":
            rom = r
            break
    if rom is None:
        raise SystemExit("no <rom index=\"0\"> node in base MRA")

    # The assembled image now includes the pack, so the base MRA's assembled
    # hashes are stale — drop them (MiSTer would otherwise flag a mismatch).
    for attr in ("asm_md5", "md5"):
        if attr in rom.attrib:
            del rom.attrib[attr]

    hdr_len = measure_header_len(rom)
    if rom_len is None:
        rom_len, ok = measure_rom_len(rom)
        if not ok:
            raise SystemExit(
                "base MRA has file-backed <part>s; pass --rom-len "
                "(assembled arcade ROM size in bytes, e.g. from the build image)"
            )
        # fully inline: measure_rom_len already counted the header
    else:
        # --rom-len is jotego's "Total 0x… bytes", which measures the regions
        # AFTER the leading header -- add it back for the true image length.
        rom_len += hdr_len
    pack_off = (rom_len + KB - 1) // KB * KB          # next 1 kB boundary
    pad = pack_off - rom_len
    units = pack_off // KB
    if units > 0xFFFF:
        raise SystemExit(f"pack offset {pack_off} exceeds 16-bit 1kB pointer")

    # 1) pad to boundary (omit if already aligned)
    if pad:
        p = ET.SubElement(rom, "part", {"repeat": str(pad)})
        p.text = "00"
    # 2) the pack as the final part.  Use a RELATIVE per-part zip= (no leading
    #    slash): mra_loader.cpp resolves the non-'/' form as "%s/mame/%s/%s" =
    #    games_root + "/mame/" + zip + "/" + member, i.e. the pack zip lives
    #    UNDER games/mame/ (a "CPS+/" subfolder), the same dir the arcade ROMs
    #    load from.  The leading-slash '/'-form resolves to games/<zip> (a folder
    #    NEXT TO mame/) and did NOT work on hardware, so it is not used.  The
    #    arcade ROM zip is still never touched — the pack is its own zip.
    part_attrs = {"name": pack_zip_name}
    if pack_zip:
        part_attrs["zip"] = pack_zip.lstrip("/")
    pk = ET.SubElement(rom, "part", part_attrs)
    pk.tail = "\n    "
    # 3) patch at byte 8: pack pointer (LE u16, 1 kB units) THEN the pad length
    #    at bytes 10-11 (LE u16, bytes).  The pad exists only to 1 kB-align the
    #    pack; it must not be streamed into the core, because bytes past the
    #    last region are written to the QSound DSP ROM at a wrapping 8 kB
    #    address and would overwrite the firmware's start (dead DSP / black
    #    screen).  jtframe_mister_dwnld stops the readback at pack_off-pad.
    patch = ET.SubElement(rom, "patch", {"offset": str(POINTER_OFFSET)})
    patch.text = (f"{units & 0xFF:02x} {(units >> 8) & 0xFF:02x} "
                  f"{pad & 0xFF:02x} {(pad >> 8) & 0xFF:02x}")
    patch.tail = "\n  "
    return tree, {"rom_len": rom_len, "pad": pad, "pack_off": pack_off,
                  "units": units, "pack_len": pack_len, "hdr_len": hdr_len}


def run(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", nargs="?", type=Path, help="base jtCPS2 MRA")
    ap.add_argument("pack", nargs="?", type=Path, help="CPS+ pack .cpk")
    ap.add_argument("--zip-name", help="pack part name as it appears inside the "
                    "pack zip (default: pack filename)")
    ap.add_argument("--pack-zip", help="relative path of the zip containing the "
                    ".cpk, as a per-part zip= override, e.g. 'CPS+/hsf2_arrange.zip'. "
                    "Resolved under games/mame/ (any leading slash is stripped).")
    ap.add_argument("--rom-len", help="assembled arcade ROM size in bytes "
                    "(hex ok); required when parts are file-backed")
    ap.add_argument("--name", help="override the <name> shown in the arcade menu")
    ap.add_argument("--rbf", default="jtcps2-cpsplus",
                    help="core RBF the MRA binds to (default jtcps2-cpsplus — the "
                    "opt-in CPS+ core; the name must NOT be <stock>_<suffix>, "
                    "because MiSTer's get_rbf() treats '_' as a version separator "
                    "and picks the alphabetically-last match -- jtcps1_cpsplus.rbf "
                    "hijacked every stock <rbf>jtcps1</rbf> MRA). Pass --rbf jtcps2 "
                    "to target the stock core.")
    ap.add_argument("-o", "--out", type=Path, help="output MRA (default stdout)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _selftest()
    if not args.base or not args.pack:
        ap.error("base MRA and pack are required")

    magic = args.pack.open("rb").read(4)
    if magic != MAGIC:
        raise SystemExit(f"{args.pack}: not a CPS+ pack (magic {magic!r})")
    pack_len = args.pack.stat().st_size
    rom_len = int(args.rom_len, 0) if args.rom_len else None
    zip_name = args.zip_name or args.pack.name

    tree, info = embed(str(args.base), pack_len, zip_name, rom_len, args.pack_zip,
                       args.name, args.rbf)
    out = ET.tostring(tree.getroot(), encoding="unicode")
    if args.out:
        args.out.write_text(out)
        where = str(args.out)
    else:
        sys.stdout.write(out)
        where = "stdout"
    sys.stderr.write(
        f"embedded {zip_name} ({pack_len} B) at ROM offset 0x{info['pack_off']:x} "
        f"(pad {info['pad']} B, pointer {info['units']} kB-units) -> {where}\n")
    return 0


def _selftest():
    import io
    base = ('<misterromdescription><rom index="0" zip="game.zip">'
            '<part>0011 2233</part><part repeat="6">00</part>'
            '</rom></misterromdescription>')
    p = Path("/tmp/_cpsplus_selftest_base.mra"); p.write_text(base)
    tree, info = embed(str(p), pack_len=4096, pack_zip_name="game.cpk", rom_len=None)
    # 4 inline + 6 pad = 10 bytes measured; next 1kB boundary = 1024
    assert info["rom_len"] == 10, info
    assert info["pack_off"] == 1024 and info["units"] == 1, info
    rom = tree.getroot().find("rom")
    patch = rom.find("patch")
    assert patch.get("offset") == "8" and patch.text == "01 00 f6 03", patch.text
    names = [pt.get("name") for pt in rom.findall("part") if pt.get("name")]
    assert names == ["game.cpk"], names
    # pad part = 1024-10 = 1014 zero bytes
    pads = [pt for pt in rom.findall("part") if pt.get("repeat") and pt.text == "00"]
    assert any(pt.get("repeat") == "1014" for pt in pads), [pt.get("repeat") for pt in pads]
    # explicit rom-len path (file-backed arcade parts) + asm_md5 strip + pack-zip
    base2 = ('<misterromdescription><rom index="0" zip="hsf2.zip|qsound.zip" '
             'asm_md5="deadbeef" md5="None"><part name="a.03"/></rom>'
             '</misterromdescription>')
    p2 = Path("/tmp/_cpsplus_selftest_base2.mra"); p2.write_text(base2)
    tree2, info2 = embed(str(p2), 4096, "game.cpk", rom_len=0xC00000,
                         pack_zip="CPSPlus/hsf2_arrange.zip")
    assert info2["pack_off"] == 0xC00000 and info2["units"] == 0xC00000 // KB, info2
    rom2 = tree2.getroot().find("rom")
    assert "asm_md5" not in rom2.attrib and "md5" not in rom2.attrib, rom2.attrib
    # arcade zip= list left untouched; pack rides its own per-part zip=
    assert rom2.get("zip") == "hsf2.zip|qsound.zip", rom2.get("zip")
    pk = [pt for pt in rom2.findall("part") if pt.get("name") == "game.cpk"][0]
    assert pk.get("zip") == "CPSPlus/hsf2_arrange.zip", pk.get("zip")

    # --- leading MRA header must be added to --rom-len (regression) ---------
    # A real jtcores MRA opens with an inline header (64 B CPS1 / 44 B CPS2);
    # jotego's "Total 0x… bytes" counts the regions AFTER it.  Ignoring the
    # header put the pack `hdr` bytes past its own pointer -> no CP2A at the
    # pointer -> silent fail-open on hardware.  Pin the arithmetic here.
    hdr64 = " ".join(["00"] * 64)
    base3 = ('<misterromdescription><rom index="0" zip="sf2uk.zip">'
             f'<part>{hdr64}</part><interleave output="16">'
             '<part name="a.11f" map="01"/><part name="b.11e" map="10"/>'
             '</interleave></rom></misterromdescription>')
    p3 = Path("/tmp/_cpsplus_selftest_base3.mra"); p3.write_text(base3)
    tree3, info3 = embed(str(p3), 4096, "game.cpk", rom_len=0x750000)
    assert info3["hdr_len"] == 64, info3
    # true image = 64 + 0x750000 = 0x750040 -> next 1 kB boundary 0x750400
    assert info3["pack_off"] == 0x750400, hex(info3["pack_off"])
    assert info3["pad"] == 0x750400 - 0x750040, info3["pad"]
    assert info3["units"] == 0x750400 // KB == 0x1D41, info3["units"]
    rom3 = tree3.getroot().find("rom")
    patch3 = rom3.find("patch")
    # pointer 0x1D41 (LE) then pad 960 = 0x03C0 (LE) at bytes 10-11
    assert patch3.text == "41 1d c0 03", patch3.text
    # the pad must land the pack exactly on the pointer it advertises
    assert info3["hdr_len"] + 0x750000 + info3["pad"] == info3["units"] * KB
    print("embed_pack_mra self-test: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(run())
