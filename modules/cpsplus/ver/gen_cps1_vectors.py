#!/usr/bin/env python3
"""Vector generator for tb_cps1_tap.v (cpsplus_cps1_tap RTL acceptance).

CPS1 (jtcps1) sound is a fire-and-forget single-byte register latch, not the
CPS2 QSound record + handshake.  So instead of driving 68K bus cycles (as
gen_trigger_vectors.py does for cpsplus_trigger), this generator drives a
sequence of command-latch VALUES and, for each, the expected suppression
level (`sub`) plus the verb events the tap must emit.

Runs:
  * sf2_trace   — replay of the validated Phase-0 latch trace slice
    (manifests/protocol/sf2.json `command_events_first_64`, a deterministic
    attract+demo route through boot / title / char-select / a demo fight on
    the Guile stage): boot 0xf0, section-stop 0xf7, idle 0xff, stage music
    0x05, select 0x0e, title 0x16, SFX 0x21..0x3d, voices 0x56..0x60.  The
    golden events come from the reference classifier below; the trace is a
    real MAME artifact, so this is the "divergence vs software reference"
    acceptance run.
  * directed    — corner cases on a synthetic sf2 table: every music
    command from protocols.SF2_MUSIC_COMMANDS (PLAY + suppress), a synthetic
    STOP+suppress row, an SFX pass-through, back-to-back distinct music, the
    same music twice with an idle between (both must re-fire), and the
    0xf0/0xf7/0xff control family + a voice (all pass through, no event).
  * nogate      — MODE.nogate=1 (observe-only): music still emits events but
    `sub` stays low (evt_sup=0) — the arranged track can be auditioned with
    the native music left audible.
  * disabled    — MODE.enable=0: no events, `sub` never asserts (stock core).

Outputs per run (plain-hex $readmemh files):
  <name>_cfg.hex   72 lines, {addr[23:16], data[15:0]} config writes
  <name>_trig.hex  TRIG_ROWS lines, 32-bit little-endian pack rows
  <name>_stim.hex  40-bit stimulus vectors (layout below)
  <name>_gold.hex  80-bit golden event vectors (layout below)
plus runs.txt (one line per run: name cfg trig stim gold) for the Makefile.

Stimulus vector (one command-latch value):
  [39:20] frame     [8] sub expected on this value     [7:0] latch value
Golden event vector (same layout as gen_trigger_vectors.py):
  [79:60] frame  [59:56] verb  [55:44] track  [43:36] gain
  [35:20] argw(=0)  [19:12] argb(=0)  [11:2] 0  [1] ctrl  [0] sup
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

RTL_DIR = Path(__file__).resolve().parents[1]
CPSPLUS = RTL_DIR.parent
sys.path.insert(0, str(CPSPLUS))

from pack.format import TriggerRow, VERB_PLAY, VERB_STOP, VERB_NONE  # noqa: E402
from pack import protocols as P  # noqa: E402

TRIG_ROWS = 256
CFG_LINES = 8 + 64
IDLE = 0xff             # cpsplus_cps1_tap resets cmd_cur to the idle byte


# ----------------------------------------------------------------- tables ---
class Cps1Tables:
    """sf2 protocol descriptor + 256-row trigger table + control map."""

    def __init__(self, proto, triggers, mode=0b001):
        self.p = proto
        self.triggers = triggers
        self.mode = mode                       # bit0 en, bit1 dialect, bit2 nogate
        self.idle = proto.handshake_ready      # substituted for the Z80 (0xff)
        self.ctrl_start = proto.control_region_start
        self.ctrl_dflt = proto.control_default_verb
        self.ctrl_verbs = dict(proto.control_verbs)

    # Reference classifier — mirrors cpsplus_cps1_tap.v.
    def classify(self, val):
        """-> (verb, track, gain, sup, is_ctrl)."""
        if val >= self.ctrl_start:
            return self.ctrl_verbs.get(val, self.ctrl_dflt), 0, 0, 0, 1
        r = self.triggers[val]
        return r.verb, r.track, r.gain, r.suppress, 0

    def sub_level(self, val):
        verb, _t, _g, sup, ctrl = self.classify(val)
        en = bool(self.mode & 1)       # MODE bit0
        nogate = bool(self.mode & 4)   # MODE bit2 (bit1 = dialect, unused here)
        return 1 if (en and not nogate and sup and not ctrl) else 0

    def cfg_words(self):
        p = self.p
        w = [
            (0x00, p.latch_page & 0xffff),
            (0x01, (p.latch_page >> 16) & 0xff),
            (0x02, (p.off_cmd_lo << 8) | p.off_cmd_hi),
            (0x03, (p.off_arg_lo << 8) | p.off_arg_hi),
            (0x04, (p.off_handshake << 8) | p.off_arg_byte),
            (0x05, (p.handshake_ready << 8) | p.handshake_pending),
            (0x06, p.control_region_start),
            (0x07, (self.mode & 0x7) | ((self.ctrl_dflt & 0x7) << 4)),
        ]
        entries = sorted(self.ctrl_verbs.items())
        assert len(entries) <= 32, "control map overflow"
        for i in range(32):
            cmd, vb = entries[i] if i < len(entries) else (0, 0)
            w.append((0x40 + 2 * i, cmd))
            w.append((0x41 + 2 * i, vb))
        assert len(w) == CFG_LINES
        return w

    def trig_words(self):
        return [int.from_bytes(r.pack(), "little") for r in self.triggers]


def synthetic_triggers():
    """A synthetic sf2 trigger table: every verified music command is a
    suppressed PLAY, plus one suppressed STOP row; everything else (SFX,
    voices, unmapped) stays verb=none."""
    trig = [TriggerRow() for _ in range(TRIG_ROWS)]
    for i, cmd in enumerate(sorted(P.SF2_MUSIC_COMMANDS)):
        trig[cmd] = TriggerRow(verb=VERB_PLAY, track=i, gain=0x60, suppress=1)
    trig[0x0f] = TriggerRow(verb=VERB_STOP, track=0, gain=0, suppress=1)
    return trig


# ------------------------------------------------------------ vector model ---
class Run:
    def __init__(self, tables: Cps1Tables):
        self.t = tables
        self.stim = []
        self.gold = []
        self.last = IDLE          # tap resets cmd_cur to the idle byte
        self.subs = 0

    def drive(self, frame, val):
        t = self.t
        sub = t.sub_level(val)
        self.subs += sub
        self.stim.append(((frame & 0xfffff) << 20) | ((sub & 1) << 8)
                         | (val & 0xff))
        if val != self.last and (t.mode & 1):
            verb, track, gain, sup, ctrl = t.classify(val)
            if verb != VERB_NONE:
                gsup = 1 if (sup and not (t.mode & 4)) else 0   # bit2 = nogate
                self.gold.append(
                    ((frame & 0xfffff) << 60) | ((verb & 0xf) << 56)
                    | ((track & 0xfff) << 44) | ((gain & 0xff) << 36)
                    | ((ctrl & 1) << 1) | (gsup & 1))
        self.last = val

    def dump(self, outdir: Path, name: str):
        outdir.mkdir(parents=True, exist_ok=True)
        p = {}
        for kind, data, width in (
                ("cfg", [(a << 16) | d for a, d in self.t.cfg_words()], 6),
                ("trig", self.t.trig_words(), 8),
                ("stim", self.stim, 10),
                ("gold", self.gold, 20)):
            f = outdir / f"{name}_{kind}.hex"
            f.write_text("".join(f"{v:0{width}x}\n" for v in data))
            p[kind] = f
        return p


# --------------------------------------------------------------- run builds ---
def build_trace(mode=0b001) -> Run:
    proto = P.get_protocol("sf2")
    tab = Cps1Tables(proto, synthetic_triggers(), mode=mode)
    run = Run(tab)
    events = json.loads((CPSPLUS / "manifests/protocol/sf2.json").read_text())
    for e in events["command_events_first_64"]:
        run.drive(int(e["frame"]), int(e["value"]) & 0xff)
    return run


def build_directed() -> Run:
    proto = P.get_protocol("sf2")
    tab = Cps1Tables(proto, synthetic_triggers(), mode=0b001)
    run = Run(tab)
    fr = 100
    seq = [
        0xf0,               # boot (control) — pass, no sub, no event
        0x16, 0xff,         # title music — sub + play; then idle releases sub
        0x21, 0xff,         # SFX — pass, no sub, no event
        0x05, 0xff,         # Guile stage music — sub + play
        0x08,               # Dhalsim music — new play (implicit stop-on-start)
        0x16, 0xff,         # back to title — new play
        0x16, 0xff, 0x16,   # same music twice with idle between -> both re-fire
        0xff,
        0x0f, 0xff,         # synthetic STOP row — sub + stop verb
        0xf7,               # section-stop control — pass, no sub, no event
        0x56, 0xff,         # announcer voice — pass, no sub, no event
        0x8c, 0xff,         # ending music (attract-unreachable) — sub + play
    ]
    for v in seq:
        run.drive(fr, v)
        fr += 1
    return run


def build_disabled() -> Run:
    proto = P.get_protocol("sf2")
    tab = Cps1Tables(proto, synthetic_triggers(), mode=0b000)   # enable=0
    run = Run(tab)
    for fr, v in enumerate((0x16, 0xff, 0x05, 0xff, 0x0f), start=100):
        run.drive(fr, v)
    return run


# ------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["all"])
    ap.add_argument("--outdir", required=True, type=Path)
    args = ap.parse_args()

    runs = [
        ("sf2_trace",    build_trace(mode=0b001)),
        ("sf2_directed", build_directed()),
        ("sf2_nogate",   build_trace(mode=0b101)),   # observe-only
        ("sf2_disabled", build_disabled()),
    ]
    manifest = []
    for name, run in runs:
        p = run.dump(args.outdir, name)
        manifest.append(f"{name} {p['cfg']} {p['trig']} {p['stim']} {p['gold']}")
        print(f"{name:14s} stim={len(run.stim):4d} gold={len(run.gold):3d} "
              f"subs={run.subs:3d}")
    (args.outdir / "runs.txt").write_text("\n".join(manifest) + "\n")
    print(f"wrote {args.outdir}/runs.txt ({len(runs)} runs)")


if __name__ == "__main__":
    main()
