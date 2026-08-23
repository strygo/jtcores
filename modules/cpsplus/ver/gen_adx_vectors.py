#!/usr/bin/env python3
"""tb_adx vector generator — real .cpk ADX streams + adxcodec golden.

Extracts a track's header-stripped ADX frame stream from a pack, computes
the golden PCM with pack/adxcodec.py py_decode (THE decode-convention
holder, ffmpeg-'scale' semantics), cross-checks it against the ffmpeg
decode, and writes tb_adx.v inputs:

    <out>/stream.hex    one hex byte per line
    <out>/golden.hex    one {R,L} 32-bit hex word per line
    <out>/plusargs.txt  vvp plusargs for this vector set

Usage:
    gen_adx_vectors.py --pack work/packs/hsf2_arrange.cpk --track 55 \
        [--frames N] --out <dir>

--frames limits to N frame groups (0/omitted = whole track).
"""
from __future__ import annotations

import argparse
import array
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]     # cpsplus/
sys.path.insert(0, str(PROJECT))
from pack import adxcodec                          # noqa: E402
from pack.format import PackReader, CODEC_ADX      # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pack", required=True)
    ap.add_argument("--track", type=int, required=True)
    ap.add_argument("--frames", type=int, default=0,
                    help="frame groups to take (0 = whole track)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    rd = PackReader(args.pack)
    try:
        m = rd.tracks[args.track]
        if m.codec != CODEC_ADX:
            raise SystemExit(f"track {args.track} is not ADX")
        data = rd.read_track(args.track)
    finally:
        rd.close()

    fg = 18 * m.channels
    if args.frames:
        data = data[:args.frames * fg]
    ngroups = len(data) // fg
    npairs = ngroups * 32

    # golden: pure-Python reference decoder (bit-exact vs ffmpeg, selftest)
    py = adxcodec.py_decode(data, m.channels, m.coef1, m.coef2)
    assert len(py[0]) == npairs, (len(py[0]), npairs)

    # cross-check against the ffmpeg bridge on the same stream
    ff = array.array("h")
    ff.frombytes(adxcodec.decode(data, m.channels, m.sample_rate,
                                 total_samples=npairs))
    for i in range(npairs):
        for c in range(m.channels):
            if ff[i * m.channels + c] != py[c][i]:
                raise SystemExit(
                    f"py_decode vs ffmpeg divergence at sample {i} ch {c}: "
                    f"{py[c][i]} vs {ff[i * m.channels + c]}")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "stream.hex", "w") as f:
        f.write("\n".join(f"{b:02x}" for b in data) + "\n")
    with open(out / "golden.hex", "w") as f:
        right = py[1] if m.channels == 2 else py[0]
        f.write("\n".join(
            f"{((right[i] & 0xffff) << 16) | (py[0][i] & 0xffff):08x}"
            for i in range(npairs)) + "\n")
    plus = (f"+STREAM={out / 'stream.hex'} +GOLD={out / 'golden.hex'} "
            f"+NBYTES={len(data)} +NPAIRS={npairs} "
            f"+STEREO={1 if m.channels == 2 else 0} "
            f"+C1={m.coef1 & 0xffff} +C2={m.coef2 & 0xffff}")
    (out / "plusargs.txt").write_text(plus + "\n")
    print(f"[gen_adx] track {args.track} ({m.name or '?'}): {ngroups} frame "
          f"groups, {npairs} pairs, c1={m.coef1} c2={m.coef2} "
          f"ch={m.channels} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
