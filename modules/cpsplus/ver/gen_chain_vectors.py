#!/usr/bin/env python3
"""Vector generator for tb_ddr.v (cpsplus_ddr unit acceptance) and
tb_chain.v (Phase-3 full-chain acceptance: trigger + ddr + player).

Reuses the gen_trigger_vectors.py machinery (Tables = pack protocol +
trigger table + reference classifier) and the pack toolchain oracles
(pack.format reader/writer, pack.audition render).

mode `ddr` — unit vectors for tb_ddr.v:
  * a tiny synthetic pack written by pack.format.PackWriter (the
    normative layout writer): 2 tracks (stereo ADX-tagged + mono PCM,
    opaque bytes — cpsplus_ddr never decodes), play triggers 0x10/0x11,
    a 5-entry control-verb map, Anthology fade law.
  * images: win_ind.hex = 64 B MRA-header stub (pack pointer at bytes
    8-9, 1 kB units) + pack at +0x400; win_bad.hex = pack at +0 with a
    corrupted magic; stub64.hex = header stub with the 0xFFFF fill
    pointer (no pack appended).
  * goldens: cfg_gold.hex (72 x {addr,data16}, the exact cpsplus_trigger
    config image, MODE with enable=1), trig_gold.hex (TRIG_ROWS x 32-bit
    rows incl. zero fill), track-register plusargs for both tracks.

mode `chain` — the Phase-3 acceptance run:
  * DDR window image: MRA stub + the REAL work/packs/hsf2_arrange.cpk
    header/trigger/index sections + ONE track's data (track 54, the
    smallest looped track), REL0CATED: index entry 54's data_offset is
    patched to 0 and the track bytes placed at header.data_offset, so
    the 184 MB pack windows down to ~0.8 MB.  All other index entries
    keep their original (out-of-window) offsets; the TB's DDR model
    returns zeros there, so the log's preceding track-53 play streams
    silence — which also exercises a mid-play restart over the backend.
  * stimulus: the Phase-2 hsf2 fight log rows (work/phase2/hsf2_fight/
    run_a/hsf2_events.tsv) in the frame window [5509..6350] — ctrl stop,
    two suppressed plays (0x0036 -> t53, 0x0037 -> t54), SFX records —
    plus an injected HSF2-law fade (0xff06, argw 0x0444 -> 60 frames to
    silence) after the loop wrap and the driver's stop (0xff00) mid-fade.
    Each bus vector carries a `thr` field: the TB waits until it has
    collected >= thr sample pairs (counted from the designated play)
    before driving it.
  * goldens: the verb-event sequence (classified via the pack tables,
    identical semantics to the validated Phase-2 prototype) and the PCM
    stream of track 54 = pack.audition.render intro + loop passes with
    the exact RTL volume law applied, compared sample-exactly across the
    loop wrap until the fade onset.

Stimulus vector (24 hex chars, one 68K bus cycle):
  [95:64] thr        collected-pairs threshold before driving
  [63:60] flags      bit0 gate expected, bit1 run fade check after,
                     bit2 run stop check after
  [59:36] {1'b0, addr[23:1]}
  [35:20] dout16     [19:18] dsn   [17] rnw   [16] cs   [15:0] 0

Golden event vector: gen_trigger_vectors.py layout (frame field is
reference-only in the chain TB; ordering is what is checked).
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

TB_DIR  = Path(__file__).resolve().parent
RTL_DIR = TB_DIR.parent
CPSPLUS = RTL_DIR.parent
sys.path.insert(0, str(CPSPLUS))
sys.path.insert(0, str(TB_DIR))

from pack.format import (PackReader, PackWriter, Protocol, TrackMeta,   # noqa: E402
                         TriggerRow, CODEC_ADX, CODEC_PCM, VERB_PLAY,
                         VERB_STOP, VERB_FADE_OUT, VERB_FADE_KEEP,
                         VERB_RESTORE, VERB_MASTER_FADE, FADE_ANTHOLOGY,
                         TRACK_INDEX_SIZE)
from pack.audition import render                                        # noqa: E402
from gen_trigger_vectors import Tables, TRIG_ROWS                       # noqa: E402

IMG_BASE  = 0x30000000        # MRA ROM image base in DDR (research §4)
PACK_1KB  = 1                 # pack offset in the stub image, 1 kB units
HSF2_PACK = CPSPLUS / "work" / "packs" / "hsf2_arrange.cpk"
HSF2_LOG  = CPSPLUS / "work" / "phase2" / "hsf2_fight" / "run_a" / \
            "hsf2_events.tsv"

UNITY24 = 0x800000


# ------------------------------------------------------------- helpers ----
def mra_stub(pack_1kb: int | None) -> bytearray:
    """64-byte MRA-header stand-in: 0xFF fill (the jtframe header fill),
    bytes 8-9 = pack offset in 1 kB units (little-endian), 0xFFFF = no
    pack.  Only bytes 8-9 are consumed by cpsplus_ddr."""
    h = bytearray(b"\xff" * 64)
    if pack_1kb is not None:
        struct.pack_into("<H", h, 8, pack_1kb)
    return h


def write_hex_bytes(path: Path, data: bytes):
    with open(path, "w") as f:
        f.write("\n".join(f"{b:02x}" for b in data) + "\n")


def write_hex_words(path: Path, words, width: int):
    with open(path, "w") as f:
        f.write("\n".join(f"{w:0{width}x}" for w in words) + "\n")


def write_plusargs(path: Path, plus: dict):
    path.write_text(" ".join(f"+{k}={v}" for k, v in plus.items()) + "\n")


def vol_q14(tgain: int, kgain: int) -> int:
    return ((tgain * kgain) << 14) // 16129


def pcm_words(pcm: bytes, channels: int, vq14: int, limit: int):
    import array
    a = array.array("h")
    a.frombytes(pcm)
    n = min(len(a) // channels, limit)
    out = []
    for i in range(n):
        l = (a[i * channels] * vq14) >> 14
        r = (a[i * channels + 1] * vq14) >> 14 if channels == 2 else l
        out.append(((r & 0xffff) << 16) | (l & 0xffff))
    return out


# ---------------------------------------------------------- chain vectors --
class ChainRun:
    """Bus-cycle vectors with pair-count thresholds + golden events."""

    def __init__(self, tables: Tables):
        self.t = tables
        self.stim = []
        self.gold = []
        self.latch = {}
        self.n_play = 0

    def _vec(self, thr, addr_b, dout, dsn, rnw=0, cs=1, flags=0):
        assert addr_b % 2 == 0
        v = ((thr & 0xffffffff) << 64) | ((flags & 0xf) << 60) \
            | (((addr_b >> 1) & 0x7fffff) << 36) | ((dout & 0xffff) << 20) \
            | ((dsn & 3) << 18) | ((rnw & 1) << 17) | ((cs & 1) << 16)
        self.stim.append(v)

    def _gold(self, frame, verb, track, gain, argw, argb, ctrl, sup):
        v = ((frame & 0xfffff) << 60) | ((verb & 0xf) << 56) \
            | ((track & 0xfff) << 44) | ((gain & 0xff) << 36) \
            | ((argw & 0xffff) << 20) | ((argb & 0xff) << 12) \
            | ((ctrl & 1) << 1) | (sup & 1)
        self.gold.append(v)

    def write_byte(self, thr, off, val, frame=0, flags=0):
        """Low-lane byte write; classifies handshake writes for goldens."""
        assert off % 2 == 1
        t = self.t
        addr_b = (t.latch_page + off) & ~1
        gate = 0
        if off == t.off_hs and val == t.hs_pending:
            cmd = (self.latch.get(t.off_cmd_hi, 0) << 8) \
                | self.latch.get(t.off_cmd_lo, 0)
            verb, track, gain, sup, ctrl = t.classify(cmd)
            gate = 1 if sup else 0
            if verb != 0:
                argw = (self.latch.get(t.off_arg_hi, 0) << 8) \
                    | self.latch.get(t.off_arg_lo, 0)
                argb = self.latch.get(t.off_arg_byte, 0) \
                    if t.off_arg_byte else 0
                self._gold(frame, verb, track, gain, argw, argb, ctrl, gate)
                if verb == VERB_PLAY:
                    self.n_play += 1
        elif off != t.off_hs:
            if off in (t.off_cmd_hi, t.off_cmd_lo, t.off_arg_hi,
                       t.off_arg_lo) or \
                    (t.off_arg_byte and off == t.off_arg_byte):
                self.latch[off] = val
        self._vec(thr, addr_b, val & 0xff | (val & 0xff) << 8, 0b10,
                  flags=flags | (gate & 1))

    def record(self, thr, cmd, argw=0, argb=0, hs_val=None, frame=0,
               flags=0):
        t = self.t
        self.write_byte(thr, t.off_arg_hi, (argw >> 8) & 0xff)
        self.write_byte(0,   t.off_arg_lo, argw & 0xff)
        self.write_byte(0,   t.off_cmd_hi, (cmd >> 8) & 0xff)
        self.write_byte(0,   t.off_cmd_lo, cmd & 0xff)
        if t.off_arg_byte:
            self.write_byte(0, t.off_arg_byte, argb & 0xff)
        self.write_byte(0, t.off_hs,
                        t.hs_pending if hs_val is None else hs_val,
                        frame=frame, flags=flags)


def build_chain(args, out: Path):
    rd = PackReader(args.pack)
    h = rd.header
    trk = args.track
    m = rd.tracks[trk]
    assert m.loops, "chain test track must loop"

    # ---- window image: MRA stub + header/tables + relocated track data
    with open(args.pack, "rb") as f:
        head = bytearray(f.read(h.data_offset))     # header + trig + index
    ent = h.index_offset + trk * TRACK_INDEX_SIZE
    struct.pack_into("<I", head, ent, 0)            # relocate: offset -> 0
    data = rd.read_track(trk)
    pack_off = PACK_1KB << 10
    img = bytearray(mra_stub(PACK_1KB))
    img += b"\0" * (pack_off - len(img))
    img += head + data
    wsize = len(img)

    # ---- stimulus from the Phase-2 log window + injected fade/stop
    tab = Tables.from_pack(args.pack)
    run = ChainRun(tab)
    f0, f1 = args.win
    n_events_pre = 0
    rows = []
    with open(args.log) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        col = {c: i for i, c in enumerate(header)}
        for line in fh:
            fs = line.rstrip("\n").split("\t")
            frame = int(fs[col["frame"]])
            if frame < f0 or frame > f1 or fs[col["kind"]] not in \
                    ("rec", "init"):
                continue
            rows.append((frame, fs))

    play_seen = 0
    sfx_i = 0
    reset_evt = None
    for frame, fs in rows:
        if fs[col["kind"]] == "init":
            run.write_byte(0, tab.off_hs, int(fs[col["val"]], 0),
                           frame=frame)
            continue
        cmd = int(fs[col["cmd"]], 0)
        argw = int(fs[col["argw"]], 0)
        verb, track, gain, sup, ctrl = tab.classify(cmd)
        if verb == VERB_PLAY:
            play_seen += 1
            thr = 0 if play_seen == 1 else args.play2_at
            if play_seen == 2:
                reset_evt = len(run.gold)      # golden index of this play
        elif verb == 0 and not ctrl:
            thr = 5000 + 3000 * sfx_i          # SFX spread over playback
            sfx_i += 1
        else:
            thr = 0
        run.record(thr, cmd, argw=argw,
                   hs_val=int(fs[col["val"]], 0), frame=frame)
    assert play_seen == 2 and reset_evt is not None, \
        "window must contain exactly the t53 + t54 plays"

    # injected fade (HSF2 law, 0x444/0x444 x 60 = 60 frames to silence),
    # then the driver-style stop mid-fade
    run.record(args.fade_at, 0xff06, argw=0x0444, frame=99991, flags=0b0010)
    run.record(args.stop_at, 0xff00, argw=0x0000, frame=99992, flags=0b0100)

    # ---- goldens
    row = rd.triggers[0x37]
    assert row.track == trk
    vq = vol_q14(row.gain, m.gain)
    pcm, _ = render(rd, trk, loops=2)
    words = pcm_words(pcm, m.channels, vq, args.ngold)
    assert len(words) == args.ngold

    wrap_pairs = m.loop_end_byte // (18 * m.channels) * 32
    frames = (0x444 // 0x444) * 60
    step = (UNITY24 - 0) // frames

    out.mkdir(parents=True, exist_ok=True)
    write_hex_bytes(out / "win.hex", img)
    write_hex_words(out / "stim.hex", run.stim, 24)
    write_hex_words(out / "evt_gold.hex", run.gold, 20)
    write_hex_words(out / "pcm_gold.hex", words, 8)
    write_plusargs(out / "plusargs.txt", {
        "WIN": out / "win.hex", "WBASE": IMG_BASE, "WSIZE": wsize,
        "BASE": IMG_BASE, "INDIRECT": 1,
        "STIM": out / "stim.hex", "EVT": out / "evt_gold.hex",
        "GOLD": out / "pcm_gold.hex", "NGOLD": args.ngold,
        "RESET_EVT": reset_evt, "VQ14": vq,
        "FADE_EXP_FRAMES": frames, "FADE_EXP_STEP": step,
        "FADE_EXP_TGT": 0,
        "TICK": args.tick, "FDIV": args.fdiv,
    })
    rd.close()
    print(f"[chain] window {wsize} B (track {trk} '{m.name}' relocated), "
          f"{len(run.stim)} bus vectors, {len(run.gold)} golden events "
          f"(reset at #{reset_evt}), {len(words)} golden pairs "
          f"(wrap at {wrap_pairs}), vol_q14={vq}, fade {frames} frames "
          f"step {step}")


# ------------------------------------------------------------ ddr vectors --
def build_ddr(args, out: Path):
    out.mkdir(parents=True, exist_ok=True)
    proto = Protocol(
        game_id="tbddr", latch_page=0x618000,
        fade_law=FADE_ANTHOLOGY, fade_const1=0xffff, fade_const2=0,
        control_default_verb=0, control_region_start=0xff00,
        control_verbs={0xff00: VERB_STOP, 0xff06: VERB_FADE_OUT,
                       0xff07: VERB_FADE_KEEP, 0xff0c: VERB_RESTORE,
                       0xff0d: VERB_MASTER_FADE})
    w = PackWriter(proto, title="tb_ddr synthetic")
    # opaque payloads — cpsplus_ddr never decodes track data
    t0_data = bytes((7 * i + 3) & 0x7f for i in range(36 * 100))  # 100 grp
    t0 = w.add_track(t0_data, TrackMeta(
        sample_rate=48000, channels=2, codec=CODEC_ADX, gain=0x6f,
        loop_start_sample=320, loop_start_byte=10 * 36,
        loop_end_sample=3200, loop_end_byte=100 * 36,
        coef1=7400, coef2=-3343))
    t1_data = bytes((5 * i + 11) & 0xff for i in range(2 * 1000))
    t1 = w.add_track(t1_data, TrackMeta(
        sample_rate=32000, channels=1, codec=CODEC_PCM, gain=0x7f))
    w.set_trigger(0x10, TriggerRow(verb=VERB_PLAY, track=t0, gain=100,
                                   suppress=1))
    w.set_trigger(0x11, TriggerRow(verb=VERB_PLAY, track=t1, gain=0x7f,
                                   suppress=0))
    pack_path = out / "tbddr.cpk"
    w.write(pack_path, sidecar=False)
    pack = pack_path.read_bytes()

    # images
    pack_off = PACK_1KB << 10
    img = bytearray(mra_stub(PACK_1KB))
    img += b"\0" * (pack_off - len(img))
    img += pack
    write_hex_bytes(out / "win_ind.hex", img)
    bad = bytearray(pack)
    bad[0] ^= 0xff
    write_hex_bytes(out / "win_bad.hex", bad)
    write_hex_bytes(out / "stub64.hex", mra_stub(None))

    # goldens: exact trigger config + table images
    tab = Tables.from_pack(pack_path)
    cfg = [(a << 16) | d for a, d in tab.cfg_words()]
    write_hex_words(out / "cfg_gold.hex", cfg, 6)
    write_hex_words(out / "trig_gold.hex", tab.trig_words(), 8)

    rd = PackReader(pack_path)
    h = rd.header
    base_ind = IMG_BASE + pack_off
    plus = {
        "WIN": out / "win_ind.hex", "WBASE": IMG_BASE, "WSIZE": len(img),
        "BASE": IMG_BASE, "INDIRECT": 1,
        "CFG_GOLD": out / "cfg_gold.hex", "TRIG_GOLD": out / "trig_gold.hex",
        "NCFG": len(cfg), "NTRIG": TRIG_ROWS,
    }
    for i, name in ((t0, "T0"), (t1, "T1")):
        m = rd.tracks[i]
        plus.update({
            f"{name}_TRACK": i,
            f"{name}_GAIN_TRIG": rd.triggers[0x10 + i].gain,
            f"{name}_ADDR": base_ind + h.data_offset + m.data_offset,
            f"{name}_LEN": m.data_length,
            f"{name}_LSTART": m.loop_start_byte,
            f"{name}_LEND": m.loop_end_byte,
            f"{name}_STEREO": m.channels - 1,
            f"{name}_CODEC": m.codec,
            f"{name}_GAIN": m.gain,
            f"{name}_C1": m.coef1 & 0xffff,
            f"{name}_C2": m.coef2 & 0xffff,
            f"{name}_RATE": m.sample_rate,
        })
    plus.update({"LAW": h.proto.fade_law, "CONST1": h.proto.fade_const1,
                 "CONST2": h.proto.fade_const2})
    write_plusargs(out / "plusargs_good.txt", plus)
    write_plusargs(out / "plusargs_bad.txt", {
        "WIN": out / "win_bad.hex", "WBASE": IMG_BASE, "WSIZE": len(bad),
        "BASE": IMG_BASE, "INDIRECT": 0, "EXPECT_FAIL": 5,
    })
    write_plusargs(out / "plusargs_nopack.txt", {
        "WIN": out / "stub64.hex", "WBASE": IMG_BASE, "WSIZE": 64,
        "BASE": IMG_BASE, "INDIRECT": 1, "EXPECT_FAIL": 4,
    })
    rd.close()
    print(f"[ddr] synthetic pack {len(pack)} B, image {len(img)} B, "
          f"{len(cfg)} cfg words, tracks t0/t1 golden regs written")


# ------------------------------------------------------------------- main --
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", required=True, choices=["ddr", "chain"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--pack", default=str(HSF2_PACK))
    ap.add_argument("--log", default=str(HSF2_LOG))
    ap.add_argument("--track", type=int, default=54)
    ap.add_argument("--win", type=int, nargs=2, default=(5509, 6350),
                    help="Phase-2 log frame window")
    ap.add_argument("--play2-at", type=int, default=2000,
                    help="pairs before the second (t54) play is driven")
    ap.add_argument("--fade-at", type=int, default=690000,
                    help="pairs (post-reset) before the injected fade")
    ap.add_argument("--stop-at", type=int, default=693000)
    ap.add_argument("--ngold", type=int, default=690000)
    ap.add_argument("--tick", type=int, default=8)
    ap.add_argument("--fdiv", type=int, default=100)
    args = ap.parse_args()
    out = Path(args.out).resolve()
    if args.mode == "ddr":
        build_ddr(args, out)
    else:
        build_chain(args, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
