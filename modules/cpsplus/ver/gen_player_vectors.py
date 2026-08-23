#!/usr/bin/env python3
"""tb_player vector generator.

Modes (each writes <out>/{mem.hex, golden.hex, plusargs.txt}):

  loop      REAL pack track (default 54, smallest looped HSF2 Arrange
            track): golden = intro + 2 loop passes rendered by the audition
            machinery (pack/audition.py render).  Sample-exact across both
            loop wraps — this is the predictor snapshot/restore proof.
  restart   same vectors as `loop` (generate `loop` first); re-starts the
            track after ~1 frame of playback (plus a racing double start)
            and expects the stream from sample 0 again, bit-exactly.
  stop      same vectors as `loop`; stop verb after 5000 pairs -> silence
            within one sample tick.
  monoadx   synthetic looped MONO ADX track (loop_end < data end): covers
            the mono decode path and a wrap that is not at end-of-stream.
  pcm       synthetic looped stereo PCM s16le track at non-unity gain
            (trigger 0x40 x track 0x7f): passthrough + exact volume law.
  pcm_mono  synthetic one-shot mono PCM track: drain -> track_done.
  fade1     Anthology fade law (0xffff/arg), mirroring render_route.py's
            self-test values: fade-to-half over 31 frames (arg 0x800),
            restore, fade-out to silence over 85 frames (arg 0x300) with
            auto-stop.  Exact frames/step/level expectations.
  fade2     HSF2 fade law ((0x444/arg) x 60): 60-frame fade down, then a
            fade UP with loop-off (verb 3) -> track ends at loop_end.

All expectations are exact integer mirrors of the RTL laws documented in
rtl/PLAYER.md.
"""
from __future__ import annotations

import argparse
import array
import struct
import sys
from math import sin, pi
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]     # cpsplus/
sys.path.insert(0, str(PROJECT))
from pack import adxcodec, xfade                   # noqa: E402
from pack.format import PackReader                 # noqa: E402
from pack.audition import render                   # noqa: E402

TRK_ADDR = 64          # track stream base byte address in the memory image
UNITY24 = 0x800000     # fade level Q15.8 unity
RESTORE_FRAMES = 8
XFADE_N_TB = 256       # crossfade length used by the tb (== tb_player XFADE_N)


# ------------------------------------------------- exact RTL law mirrors ----
def vol_q14(tgain: int, kgain: int) -> int:
    return ((tgain * kgain) << 14) // 16129


def tgt_q15(t: int) -> int:
    return 32768 if t == 127 else t * 258


def law_frames(law: int, c1: int, c2: int, arg: int) -> int:
    q = c1 // (arg if arg else 1)
    if law == 2:
        return min(q, 0xffff) * c2
    return q if q else 1


def fade_step(lvl24: int, t24: int, frames: int) -> int:
    return abs(lvl24 - t24) // (frames if frames else 1)


def steady_sample(amp: int, vq14: int, lvl_q15: int) -> int:
    total = (vq14 * lvl_q15) >> 15
    return (amp * total) >> 14


# ------------------------------------------------------------- helpers ----
def pcm_to_words(pcm: bytes, channels: int, vq14: int = 16384) -> list[int]:
    a = array.array("h")
    a.frombytes(pcm)
    n = len(a) // channels
    out = []
    for i in range(n):
        l = (a[i * channels] * vq14) >> 14
        r = (a[i * channels + 1] * vq14) >> 14 if channels == 2 else l
        out.append(((r & 0xffff) << 16) | (l & 0xffff))
    return out


def splice(pcm: bytes, channels: int, start_smp: int, end_smp: int,
           loops: int = 2) -> bytes:
    fb = 2 * channels
    return pcm[:end_smp * fb] + pcm[start_smp * fb:end_smp * fb] * loops


def sine_pcm(n: int, rate: int, freq: float, amp: int, ch: int) -> bytes:
    a = array.array("h")
    for i in range(n):
        v = int(amp * sin(2 * pi * freq * i / rate))
        a.append(v)
        if ch == 2:
            a.append(-v)
    return a.tobytes()


def write_vec(out: Path, mem: bytes | None, words: list[int] | None,
              plus: dict):
    out.mkdir(parents=True, exist_ok=True)
    if mem is not None:
        with open(out / "mem.hex", "w") as f:
            f.write("\n".join(f"{b:02x}" for b in mem) + "\n")
    if words is not None:
        with open(out / "golden.hex", "w") as f:
            f.write("\n".join(f"{w:08x}" for w in words) + "\n")
    (out / "plusargs.txt").write_text(
        " ".join(f"+{k}={v}" for k, v in plus.items()) + "\n")


def base_plus(out: Path, *, length: int, lstart: int, lend: int, stereo: int,
              codec: int, c1: int = 0, c2: int = 0, gain: int = 127,
              tgain: int = 127, ngold: int = 0, mem_dir: Path | None = None,
              **extra) -> dict:
    d = mem_dir if mem_dir is not None else out
    plus = {
        "MEM": d / "mem.hex", "GOLD": d / "golden.hex", "NGOLD": ngold,
        "TRK_ADDR": TRK_ADDR, "TRK_LEN": length,
        "LSTART": lstart, "LEND": lend, "STEREO": stereo, "CODEC": codec,
        "C1": c1 & 0xffff, "C2": c2 & 0xffff, "GAIN": gain, "TGAIN": tgain,
    }
    plus.update(extra)
    return plus


# ---------------------------------------------------------------- modes ----
def mode_loop(args, out: Path):
    rd = PackReader(args.pack)
    try:
        m = rd.tracks[args.track]
        data = rd.read_track(args.track)
        pcm, _ = render(rd, args.track, loops=2)   # audition machinery
    finally:
        rd.close()
    words = pcm_to_words(pcm, m.channels)          # unity gain
    mem = bytes(TRK_ADDR) + data
    plus = base_plus(out, length=m.data_length, lstart=m.loop_start_byte,
                     lend=m.loop_end_byte, stereo=m.channels - 1, codec=0,
                     c1=m.coef1, c2=m.coef2, ngold=len(words),
                     EXP_VOLQ14=16384)
    write_vec(out, mem, words, plus)
    print(f"[loop] track {args.track} ({m.name}): {len(words)} golden pairs "
          f"(intro {m.loop_end_byte // (18 * m.channels) * 32} + 2 loop "
          f"passes)")


def mode_restart(args, out: Path, loop_dir: Path):
    rd = PackReader(args.pack)
    m = rd.tracks[args.track]
    rd.close()
    plus = base_plus(out, length=m.data_length, lstart=m.loop_start_byte,
                     lend=m.loop_end_byte, stereo=m.channels - 1, codec=0,
                     c1=m.coef1, c2=m.coef2, ngold=40000, mem_dir=loop_dir,
                     RESTART_AT=800, RESTART_DOUBLE=1)
    write_vec(out, None, None, plus)
    print("[restart] restart at 800 pairs (~1 frame) + racing double start, "
          "40000 pairs compared from sample 0")


def mode_stop(args, out: Path, loop_dir: Path):
    rd = PackReader(args.pack)
    m = rd.tracks[args.track]
    rd.close()
    plus = base_plus(out, length=m.data_length, lstart=m.loop_start_byte,
                     lend=m.loop_end_byte, stereo=m.channels - 1, codec=0,
                     c1=m.coef1, c2=m.coef2, ngold=5000, mem_dir=loop_dir,
                     STOP_AT=5000)
    write_vec(out, None, None, plus)
    print("[stop] stop at 5000 pairs, silence within one tick expected")


def mode_monoadx(args, out: Path):
    rate, n = 32000, 96000
    pcm = sine_pcm(n, rate, 700.0, 11000, 1)
    stream = adxcodec.encode(pcm, 1, rate)
    c1, c2 = adxcodec.calc_coeffs(500, rate)
    assert len(stream) == 3000 * 18
    lstart_b, lend_b = 500 * 18, 2500 * 18        # loop_end < data end
    start_s, end_s = 500 * 32, 2500 * 32
    dec = adxcodec.py_decode(stream, 1, c1, c2)
    # cross-check the reference decode against ffmpeg
    ff = array.array("h")
    ff.frombytes(adxcodec.decode(stream, 1, rate))
    assert list(ff) == dec[0], "py_decode vs ffmpeg divergence"
    full = array.array("h", dec[0]).tobytes()
    gold = splice(full, 1, start_s, end_s, loops=2)
    words = pcm_to_words(gold, 1)
    mem = bytes(TRK_ADDR) + stream
    plus = base_plus(out, length=len(stream), lstart=lstart_b, lend=lend_b,
                     stereo=0, codec=0, c1=c1, c2=c2, ngold=len(words))
    write_vec(out, mem, words, plus)
    print(f"[monoadx] mono ADX loop (end mid-stream): {len(words)} pairs")


def chirp_pcm(n: int, rate: int, f0: float, f1: float, amp: int,
              ch: int) -> bytes:
    """Frequency sweep f0->f1 (phase-continuous) so head and tail material
    differ strongly — a discriminating crossfade-blend test signal."""
    a = array.array("h")
    ph = 0.0
    for i in range(n):
        f = f0 + (f1 - f0) * i / n
        ph += 2 * pi * f / rate
        v = int(amp * sin(ph))
        a.append(v)
        if ch == 2:
            a.append(int(0.6 * amp * sin(1.5 * ph)))   # distinct R channel
    return a.tobytes()


def mode_xfade(args, out: Path):
    """Synthetic stereo ADX crossfade track (loop-with-tail).  Golden = the
    software model in pack/xfade.py — the exact fixed-point the RTL implements.
    Proves the hardware loop crossfade is bit-for-bit correct across the first
    seam (pass 0) and steady-state loop seams, incl. the ADX predictor
    snapshot/restore at loop_start+N."""
    rate, ch = 48000, 2
    n = args.xfade_n                                  # crossfade length
    ls = 1024                                         # frame-aligned
    le = ls + ((max(3 * n, 5120) + 31) // 32 * 32)    # le-ls >> n, frame-aligned
    n_src = le + n + 2048                              # enough to cover le+n
    pcm = chirp_pcm(n_src, rate, 200.0, 5000.0, 12000, ch)
    stream = adxcodec.encode(pcm, ch, rate)
    c1, c2 = adxcodec.calc_coeffs(500, rate)
    fg = 18 * ch
    ls_b = adxcodec.samples_to_stream_byte(ls, ch)
    le_b = adxcodec.samples_to_stream_byte(le, ch)
    tail_b = adxcodec.samples_to_stream_byte(n, ch)
    end_b = le_b + tail_b                             # keep the tail past le
    stored = stream[:end_b]
    assert len(stored) == end_b, "source too short for the tail"

    # golden: decode the stored stream linearly, then run the shared model
    dec = adxcodec.decode(stored, ch, rate, total_samples=end_b // fg * 32)
    a = array.array("h")
    a.frombytes(dec)
    pairs = [(a[i * ch], a[i * ch + 1]) for i in range(len(a) // ch)]
    lut = xfade.make_lut(n)
    out_pairs = xfade.render(pairs, ls, le, n, loops=2, lut=lut)
    words = [((r & 0xffff) << 16) | (l & 0xffff) for l, r in out_pairs]

    xfade.write_lut_hex(n, out / "xf_lut.hex")
    mem = bytes(TRK_ADDR) + stored
    plus = base_plus(out, length=len(stored), lstart=ls_b, lend=le_b,
                     stereo=1, codec=0, c1=c1, c2=c2, ngold=len(words),
                     EXP_VOLQ14=16384, XFEN=1, LSTART_SMP=ls, LEND_SMP=le,
                     LUT=out / "xf_lut.hex")
    write_vec(out, mem, words, plus)
    print(f"[xfade] stereo ADX loop-with-tail crossfade N={n}: "
          f"{len(words)} golden pairs (intro {le} + 2 loop passes), "
          f"tail {tail_b} B past loop_end")


def mode_xfcnt(args, out: Path):
    """Finite-count crossfade track (the ffight INTRO shape): stereo ADX,
    loop_count=1 -- intro, ONE crossfaded wrap, second pass, then play
    THROUGH loop_end into the stream's own outro, unblended.  The stored
    stream is the WHOLE source (finite-count storage rule).  Golden = the
    same audition/xfade model that renders the listening previews."""
    rate, ch = 48000, 2
    n = args.xfade_n
    ls = 1024
    le = ls + ((max(3 * n, 5120) + 31) // 32 * 32)
    outro = 4096                                       # material past le+n
    n_src = le + n + outro
    pcm = chirp_pcm(n_src, rate, 200.0, 5000.0, 12000, ch)
    stream = adxcodec.encode(pcm, ch, rate)            # whole stream stored
    c1, c2 = adxcodec.calc_coeffs(500, rate)
    ls_b = adxcodec.samples_to_stream_byte(ls, ch)
    le_b = adxcodec.samples_to_stream_byte(le, ch)
    total = len(stream) // (18 * ch) * 32
    dec = adxcodec.decode(stream, ch, rate, total_samples=total)
    a = array.array("h"); a.frombytes(dec)
    pairs = [(a[i * ch], a[i * ch + 1]) for i in range(len(a) // ch)]
    lut = xfade.make_lut(n)
    # count=1 -> exactly ONE blend: xfade.render(loops=L) emits L+1 blends
    out_pairs = xfade.render(pairs, ls, le, n, loops=0, lut=lut) \
        + pairs[ls + n:]                               # final pass: raw to end
    words = [((r & 0xffff) << 16) | (l & 0xffff) for l, r in out_pairs]
    xfade.write_lut_hex(n, out / "xf_lut.hex")
    mem = bytes(TRK_ADDR) + stream
    plus = base_plus(out, length=len(stream), lstart=ls_b, lend=le_b,
                     stereo=1, codec=0, c1=c1, c2=c2, ngold=len(words),
                     EXP_VOLQ14=16384, XFEN=1, LSTART_SMP=ls, LEND_SMP=le,
                     LCNT=1, LUT=out / "xf_lut.hex")
    write_vec(out, mem, words, plus)
    print(f"[xfcnt] finite crossfade count=1: {len(words)} golden pairs "
          f"(intro {le} + 1 blended wrap + play-through outro)")


def mode_hccnt(args, out: Path):
    """Finite-count hard-cut track (the ffight ENDING shape): stereo PCM,
    loop_count=3 -- intro, three hard wraps, then play THROUGH loop_end into
    the outro.  PCM passthrough keeps the golden byte-exact trivial."""
    rate, n, ch = 32000, 40000, 2
    pcm = sine_pcm(n, rate, 500.0, 13000, ch)
    ls, le = 8000, 28000
    gold = splice(pcm, ch, ls, le, loops=3) + pcm[le * 2 * ch:]
    words = pcm_to_words(gold, ch)
    mem = bytes(TRK_ADDR) + pcm
    plus = base_plus(out, length=len(pcm), lstart=ls * 2 * ch, lend=le * 2 * ch,
                     stereo=1, codec=1, ngold=len(words), LCNT=3,
                     EXPECT_END=1, TICK=12)
    write_vec(out, mem, words, plus)
    print(f"[hccnt] finite hard-cut count=3: {len(words)} pairs "
          f"(3 wraps + outro, track_done at the last sample)")


def mode_pcm(args, out: Path):
    rate, n, ch = 32000, 32000, 2
    tgain, kgain = 0x40, 0x7f
    pcm = sine_pcm(n, rate, 500.0, 13000, ch)
    lstart_b, lend_b = 8000 * 4, 28000 * 4
    gold = splice(pcm, ch, 8000, 28000, loops=2)
    vq = vol_q14(tgain, kgain)
    words = pcm_to_words(gold, ch, vq)            # exact volume law applied
    mem = bytes(TRK_ADDR) + pcm
    # TICK=12: the byte-serial PCM feed sustains ~8.75 clk/pair, so the default
    # 8-clk tick would gracefully underrun (feed slower than drain).  The
    # pipelined output stage carries one registered stage before the volume
    # multiply, so — like the fade1 vector — the tick must exceed the feed rate
    # for the delivered stream to stay sample-exact (real hardware runs the
    # frac cen at the 32/48 kHz track rate, ~2000 clk/pair, never near this).
    plus = base_plus(out, length=len(pcm), lstart=lstart_b, lend=lend_b,
                     stereo=1, codec=1, gain=kgain, tgain=tgain,
                     ngold=len(words), EXP_VOLQ14=vq, TICK=12)
    write_vec(out, mem, words, plus)
    print(f"[pcm] stereo PCM loop, gain 0x{tgain:02x}x0x{kgain:02x} "
          f"(vol_q14={vq}): {len(words)} pairs")


def mode_pcm_mono(args, out: Path):
    rate, n = 32000, 16000
    pcm = sine_pcm(n, rate, 350.0, 9000, 1)
    words = pcm_to_words(pcm, 1)
    mem = bytes(TRK_ADDR) + pcm
    plus = base_plus(out, length=len(pcm), lstart=0, lend=0, stereo=0,
                     codec=1, ngold=len(words), EXPECT_END=1,
                     END_MIN=n, END_MAX=n)
    write_vec(out, mem, words, plus)
    print(f"[pcm_mono] one-shot mono PCM: {len(words)} pairs, "
          f"track_done at {n}")


def _dc_track(amp: int, samples: int) -> bytes:
    return struct.pack("<h", amp) * 2 * samples


def mode_fade1(args, out: Path):
    amp, n = 16000, 48000
    law, c1, c2 = 1, 0xffff, 0
    pcm = _dc_track(amp, n)
    words = pcm_to_words(pcm[:2000 * 4], 2)       # unity until first fade
    mem = bytes(TRK_ADDR) + pcm

    lvl = UNITY24
    ev = {}
    # F1: fade-keep to 64/127 over 0xffff/0x800 = 31 frames
    t1 = tgt_q15(64) << 8
    f1 = law_frames(law, c1, c2, 0x800)
    ev.update(F1_AT=2000, F1_TGT=64, F1_ARG=0x800, F1_EXP_FRAMES=f1,
              F1_EXP_STEP=fade_step(lvl, t1, f1), F1_EXP_TGT=t1,
              F1_CHK_SAMPLE=1,
              F1_EXP_SAMPLE=steady_sample(amp, 16384, t1 >> 8) & 0xffff)
    lvl = t1
    # F2: restore to unity over RESTORE_FRAMES
    ev.update(F2_AT=8000, F2_RESTORE=1, F2_EXP_FRAMES=RESTORE_FRAMES,
              F2_EXP_STEP=fade_step(lvl, UNITY24, RESTORE_FRAMES),
              F2_EXP_TGT=UNITY24, F2_CHK_SAMPLE=1,
              F2_EXP_SAMPLE=amp)
    lvl = UNITY24
    # F3: fade to silence over 0xffff/0x300 = 85 frames -> auto-stop
    f3 = law_frames(law, c1, c2, 0x300)
    ev.update(F3_AT=14000, F3_TGT=0, F3_ARG=0x300, F3_EXP_FRAMES=f3,
              F3_EXP_STEP=fade_step(lvl, 0, f3), F3_EXP_TGT=0)
    # TICK=12: the PCM feed through the single-word memory port sustains
    # ~8.75 clk/pair, so the default 8-clk tick would gracefully underrun
    # and skew this test's TIME-based end-position bound (fade frames tick
    # on wall clock, `collected` only on delivered pairs)
    plus = base_plus(out, length=len(pcm), lstart=0, lend=len(pcm), stereo=1,
                     codec=1, ngold=2000, LAW=law, CONST1=c1, CONST2=c2,
                     EXP_VOLQ14=16384, EXPECT_END=1, END_MIN=22300,
                     END_MAX=22800, TICK=12, **ev)
    write_vec(out, mem, words, plus)
    print(f"[fade1] Anthology law: 31-frame fade-keep, restore, 85-frame "
          f"fade-out w/ auto-stop (steps {ev['F1_EXP_STEP']}/"
          f"{ev['F2_EXP_STEP']}/{ev['F3_EXP_STEP']})")


def mode_fade2(args, out: Path):
    amp, n = 16000, 20000
    law, c1, c2 = 2, 0x444, 60
    pcm = _dc_track(amp, n)
    words = pcm_to_words(pcm[:1000 * 4], 2)
    mem = bytes(TRK_ADDR) + pcm

    lvl = UNITY24
    ev = {}
    # F1: fade to 32/127 over (0x444/0x444) x 60 = 60 frames
    t1 = tgt_q15(32) << 8
    f1 = law_frames(law, c1, c2, 0x444)
    ev.update(F1_AT=1000, F1_TGT=32, F1_ARG=0x444, F1_EXP_FRAMES=f1,
              F1_EXP_STEP=fade_step(lvl, t1, f1), F1_EXP_TGT=t1,
              F1_CHK_SAMPLE=1,
              F1_EXP_SAMPLE=steady_sample(amp, 16384, t1 >> 8) & 0xffff)
    lvl = t1
    # F2: fade UP to 64/127 with loop-off (verb 3) -> ends at loop_end
    t2 = tgt_q15(64) << 8
    f2 = law_frames(law, c1, c2, 0x444)
    ev.update(F2_AT=8000, F2_TGT=64, F2_ARG=0x444, F2_LOOPOFF=1,
              F2_EXP_FRAMES=f2, F2_EXP_STEP=fade_step(lvl, t2, f2),
              F2_EXP_TGT=t2, F2_CHK_SAMPLE=1,
              F2_EXP_SAMPLE=steady_sample(amp, 16384, t2 >> 8) & 0xffff)
    plus = base_plus(out, length=len(pcm), lstart=4000 * 4, lend=len(pcm),
                     stereo=1, codec=1, ngold=1000, LAW=law, CONST1=c1,
                     CONST2=c2, EXP_VOLQ14=16384, EXPECT_END=1,
                     END_MIN=n, END_MAX=n, **ev)
    write_vec(out, mem, words, plus)
    print(f"[fade2] HSF2 law: 60-frame fades (down then up w/ loop-off), "
          f"track ends at loop_end sample {n}")


MODES = {
    "loop": mode_loop, "monoadx": mode_monoadx, "pcm": mode_pcm,
    "pcm_mono": mode_pcm_mono, "fade1": mode_fade1, "fade2": mode_fade2,
    "xfade": mode_xfade, "xfcnt": mode_xfcnt, "hccnt": mode_hccnt,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", required=True,
                    choices=list(MODES) + ["restart", "stop"])
    ap.add_argument("--pack", default=str(PROJECT / "work" / "packs" /
                                          "hsf2_arrange.cpk"))
    ap.add_argument("--track", type=int, default=54)
    ap.add_argument("--xfade-n", type=int, default=XFADE_N_TB,
                    help="crossfade length for the xfade mode (== tb XFADE_N)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--loop-dir", default="",
                    help="restart/stop: dir holding the `loop` mode vectors")
    args = ap.parse_args()
    out = Path(args.out).resolve()
    if args.mode in ("restart", "stop"):
        if not args.loop_dir:
            raise SystemExit("--loop-dir required for restart/stop")
        loop_dir = Path(args.loop_dir).resolve()
        if not (loop_dir / "mem.hex").exists():
            raise SystemExit(f"generate `loop` vectors first ({loop_dir})")
        (mode_restart if args.mode == "restart" else mode_stop)(
            args, out, loop_dir)
    else:
        MODES[args.mode](args, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
