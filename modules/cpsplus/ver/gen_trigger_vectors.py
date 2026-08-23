#!/usr/bin/env python3
"""Vector generator for tb_trigger.v (cpsplus_trigger RTL acceptance).

Converts the project's validated software artifacts into TB stimulus and
golden outputs:

  * phase2  — replays a Phase-2 MAME event log (work/phase2/<set>_fight/
    run_a/<set>_events.tsv, produced by lua/cpsplus_prototype.lua with
    gating enabled).  Each `rec` row is reconstructed as the record-byte
    writes plus the handshake byte write; each `init` row as a lone
    non-pending handshake write.  Golden events are the log's own verbs
    (the validated prototype), cross-checked against a fresh classification
    from the pack tables — any drift between pack and log is a hard error.
  * phase0  — replays a raw Phase-0 latch trace (work/phase0/<set>/
    <set>_latch.tsv): real 68K byte-lane traffic including the boot
    memtest word fills, 0x55/0xFF init patterns and even-lane writes.
    Golden events come from the reference model below (a 1:1 port of the
    prototype semantics with the RTL's byte-lane handshake qualification).
  * directed — synthetic corner cases per game: back-to-back plays 1 frame
    apart, full-word memtest writes to the handshake word (must pass
    untouched even with a suppressed command latched), wrong-value and
    wrong-lane handshake writes, read cycles, cs=0 writes, control verbs
    with fade arguments, unmatched control commands, unmapped music (SFX)
    commands, out-of-table commands.
  * wofpage  — synthetic CPS1.5 run: same record protocol at latch page
    0xF18000 (manifests/protocol/wof.json), tiny synthetic trigger table,
    plus a negative check that CPS2-page (0x618000) traffic is ignored.
  * wof / slammast — CPS1.5 QSound directed suites built from the
    protocols.py descriptors (latch page 0xF18000): the full corner-case
    battery (build_directed) driven at the CPS1.5 page, exercising the
    arg-byte-absent (wof, driver 1.00) and arg-byte-present (slammast,
    driver 1.01/MB) configs.  Same cpsplus_trigger RTL as CPS2 — the QSound
    tap is reused verbatim, only the pack's latch page moves; the golden
    events come from the reference model, so divergence must be zero.
  * disabled — MODE.enable=0: a suppressed play sequence must produce no
    events and no gate (stock behavior with no pack loaded).

Outputs per run (all plain-hex $readmemh files):
  <name>_cfg.hex   72 lines, {addr[23:16], data[15:0]} config writes
  <name>_trig.hex  TRIG_ROWS lines, 32-bit little-endian pack rows
  <name>_stim.hex  80-bit stimulus vectors (layout below)
  <name>_gold.hex  80-bit golden event vectors (layout below)
plus runs.txt (one line per run: name cfg trig stim gold) for the Makefile.

Stimulus vector layout (one 68K write/read bus cycle):
  [79:60] frame     [59:56] flags (bit0 = gate expected on this cycle)
  [55:32] {1'b0, addr[23:1]}
  [31:16] dout      [15:6] 0     [5:4] dsn  [3:2] 0  [1] rnw  [0] cs

Golden event vector:
  [79:60] frame     [59:56] verb  [55:44] track  [43:36] gain
  [35:20] argw      [19:12] argb  [11:2] 0       [1] ctrl    [0] sup
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

RTL_DIR = Path(__file__).resolve().parents[1]
CPSPLUS = RTL_DIR.parent
sys.path.insert(0, str(CPSPLUS))

from pack.format import PackReader, TriggerRow  # noqa: E402
from pack import protocols as P  # noqa: E402

TRIG_ROWS = 4608
CFG_LINES = 8 + 64

VERB_NUM = {"none": 0, "play": 1, "stop": 2, "fade_out": 3,
            "fade_keep": 4, "restore": 5, "master_fade": 6}

GAMES = {
    "sfau":   {"pack": "work/packs/sfa1_anthology.cpk",
               "phase2": "work/phase2/sfau_fight/run_a/sfau_events.tsv",
               "phase0": "work/phase0/sfau/sfau_latch.tsv"},
    "hsf2":   {"pack": "work/packs/hsf2_arrange.cpk",
               "phase2": "work/phase2/hsf2_fight/run_a/hsf2_events.tsv",
               "phase0": "work/phase0/hsf2_driven/hsf2_latch.tsv"},
    "sfz2al": {"pack": "work/packs/sfz2al_arrange.cpk",
               "phase2": "work/phase2/sfz2al_fight/run_a/sfz2al_events.tsv",
               "phase0": "work/phase0/sfz2al/sfz2al_latch.tsv"},
}


# ----------------------------------------------------------------- tables ---
class Tables:
    """Protocol descriptor + trigger table + control map for one run."""

    def __init__(self, proto=None, triggers=None, mode=0b001):
        self.latch_page = 0x618000
        self.off_cmd_hi, self.off_cmd_lo = 0x01, 0x03
        self.off_arg_hi, self.off_arg_lo = 0x07, 0x09
        self.off_arg_byte, self.off_hs = 0x05, 0x1f
        self.hs_pending, self.hs_ready = 0x00, 0xff
        self.ctrl_start = 0xff00
        self.ctrl_dflt = 0
        self.ctrl_verbs = {}
        self.triggers = triggers if triggers is not None \
            else [TriggerRow() for _ in range(TRIG_ROWS)]
        self.mode = mode            # bit0 en, bit1 dialect, bit2 nogate
        if proto is not None:
            self.latch_page = proto.latch_page
            self.off_cmd_hi, self.off_cmd_lo = proto.off_cmd_hi, proto.off_cmd_lo
            self.off_arg_hi, self.off_arg_lo = proto.off_arg_hi, proto.off_arg_lo
            self.off_arg_byte = proto.off_arg_byte
            self.off_hs = proto.off_handshake
            self.hs_pending = proto.handshake_pending
            self.hs_ready = proto.handshake_ready
            self.ctrl_start = proto.control_region_start
            self.ctrl_dflt = proto.control_default_verb
            self.ctrl_verbs = dict(proto.control_verbs)

    @classmethod
    def from_pack(cls, pack_path, mode=0b001):
        rd = PackReader(pack_path)
        trig = list(rd.triggers)
        trig += [TriggerRow() for _ in range(TRIG_ROWS - len(trig))]
        t = cls(proto=rd.header.proto, triggers=trig[:TRIG_ROWS], mode=mode)
        rd.close()
        return t

    def cfg_words(self):
        """(addr, data) pairs for the config port — always CFG_LINES lines."""
        w = [
            (0x00, self.latch_page & 0xffff),
            (0x01, (self.latch_page >> 16) & 0xff),
            (0x02, (self.off_cmd_lo << 8) | self.off_cmd_hi),
            (0x03, (self.off_arg_lo << 8) | self.off_arg_hi),
            (0x04, (self.off_hs << 8) | self.off_arg_byte),
            (0x05, (self.hs_ready << 8) | self.hs_pending),
            (0x06, self.ctrl_start),
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

    # Reference classifier — mirrors cpsplus_trigger.v / the Lua prototype.
    def classify(self, cmd):
        """-> (verb, track, gain, sup, is_ctrl)."""
        if cmd >= self.ctrl_start:
            return self.ctrl_verbs.get(cmd, self.ctrl_dflt), 0, 0, 0, 1
        if cmd < len(self.triggers):
            r = self.triggers[cmd]
            return r.verb, r.track, r.gain, r.suppress, 0
        return 0, 0, 0, 0, 0


# ------------------------------------------------------------ vector model ---
class Run:
    """Accumulates stimulus + golden vectors while modeling the RTL."""

    def __init__(self, tables: Tables):
        self.t = tables
        self.stim = []
        self.gold = []
        self.latch = {}          # record byte latches (offset -> value)
        self.gates = 0

    def _vec(self, frame, addr_b, dout, dsn, rnw=0, cs=1, gate=0):
        assert addr_b % 2 == 0, "bus address must be word-aligned"
        v = ((frame & 0xfffff) << 60) | ((1 if gate else 0) << 56) \
            | (((addr_b >> 1) & 0x7fffff) << 32) | ((dout & 0xffff) << 16) \
            | ((dsn & 3) << 4) | ((rnw & 1) << 1) | (cs & 1)
        self.stim.append(v)

    def _gold(self, frame, verb, track, gain, argw, argb, ctrl, sup):
        v = ((frame & 0xfffff) << 60) | ((verb & 0xf) << 56) \
            | ((track & 0xfff) << 44) | ((gain & 0xff) << 36) \
            | ((argw & 0xffff) << 20) | ((argb & 0xff) << 12) \
            | ((ctrl & 1) << 1) | (sup & 1)
        self.gold.append(v)

    # --- modeled bus operations (RTL semantics) ---
    def write_byte(self, frame, off, val, expect=True):
        """Low-lane byte write of `val` to page offset `off` (odd)."""
        assert off % 2 == 1
        t = self.t
        enabled = bool(t.mode & 1) and not (t.mode & 2)
        addr_b = (t.latch_page + off) & ~1
        gate = 0
        if enabled and off == t.off_hs and val == t.hs_pending:
            cmd = (self.latch.get(t.off_cmd_hi, 0) << 8) \
                | self.latch.get(t.off_cmd_lo, 0)
            verb, track, gain, sup, ctrl = t.classify(cmd)
            gate = 1 if (sup and not (t.mode & 4)) else 0
            if verb != 0 and expect:
                argw = (self.latch.get(t.off_arg_hi, 0) << 8) \
                    | self.latch.get(t.off_arg_lo, 0)
                argb = self.latch.get(t.off_arg_byte, 0) \
                    if t.off_arg_byte else 0
                self._gold(frame, verb, track, gain, argw, argb, ctrl, gate)
        elif enabled and off != t.off_hs:
            if off in (t.off_cmd_hi, t.off_cmd_lo, t.off_arg_hi, t.off_arg_lo) \
                    or (t.off_arg_byte and off == t.off_arg_byte):
                self.latch[off] = val
        self.gates += gate
        self._vec(frame, addr_b, val & 0xff | (val & 0xff) << 8, 0b10,
                  gate=gate and expect)

    def write_word(self, frame, addr_b, val16):
        """Full-word write: latches the odd byte, never a handshake."""
        t = self.t
        off = (addr_b | 1) - t.latch_page
        lo = val16 & 0xff
        if (t.mode & 1) and not (t.mode & 2) and 0 <= off < 0x20 \
                and off != t.off_hs:
            if off in (t.off_cmd_hi, t.off_cmd_lo, t.off_arg_hi, t.off_arg_lo) \
                    or (t.off_arg_byte and off == t.off_arg_byte):
                self.latch[off] = lo
        self._vec(frame, addr_b, val16, 0b00)

    def write_hi_byte(self, frame, off_even, val):
        """High-lane byte write (even offset) — ignored by the sniffer."""
        assert off_even % 2 == 0
        self._vec(frame, self.t.latch_page + off_even, (val & 0xff) << 8, 0b01)

    def read_word(self, frame, addr_b, val16=0):
        self._vec(frame, addr_b, val16, 0b00, rnw=1)

    def write_nocs(self, frame, addr_b, val16):
        self._vec(frame, addr_b, val16, 0b10, cs=0)

    def record(self, frame, cmd, argw=0, argb=0, hs_val=None):
        """One full record in the family's typical write order + handshake."""
        t = self.t
        self.write_byte(frame, t.off_arg_hi, (argw >> 8) & 0xff)
        self.write_byte(frame, t.off_arg_lo, argw & 0xff)
        self.write_byte(frame, t.off_cmd_hi, (cmd >> 8) & 0xff)
        self.write_byte(frame, t.off_cmd_lo, cmd & 0xff)
        if t.off_arg_byte:
            self.write_byte(frame, t.off_arg_byte, argb & 0xff)
        self.write_byte(frame, t.off_hs,
                        t.hs_pending if hs_val is None else hs_val)

    def dump(self, outdir: Path, name: str):
        outdir.mkdir(parents=True, exist_ok=True)
        p = {}
        for kind, data, width in (
                ("cfg", [(a << 16) | d for a, d in self.t.cfg_words()], 6),
                ("trig", self.t.trig_words(), 8),
                ("stim", self.stim, 20),
                ("gold", self.gold, 20)):
            f = outdir / f"{name}_{kind}.hex"
            f.write_text("".join(f"{v:0{width}x}\n" for v in data))
            p[kind] = f
        return p


# ------------------------------------------------------------ input parsers ---
def parse_phase2(tables: Tables, events_tsv: Path) -> Run:
    run = Run(tables)
    mismatch = 0
    with open(events_tsv) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        col = {c: i for i, c in enumerate(header)}
        for line in fh:
            f = line.rstrip("\n").split("\t")
            kind = f[col["kind"]]
            frame = int(f[col["frame"]])
            if kind == "init":
                run.write_byte(frame, tables.off_hs, int(f[col["val"]], 0))
                continue
            if kind != "rec":
                continue
            cmd = int(f[col["cmd"]], 0)
            argw = int(f[col["argw"]], 0)
            argb = int(f[col["argb"]], 0) if f[col["argb"]] != "-" else 0
            sup = int(f[col["sup"]])
            vname = f[col["verb"]]
            # cross-check the pack tables against the validated log
            verb, track, gain, gsup, ctrl = tables.classify(cmd)
            want = ("ctrl_" if ctrl else "") + \
                   {0: "none", 1: "play", 2: "stop", 3: "fade_out",
                    4: "fade_keep", 5: "restore", 6: "master_fade"}[verb]
            if not ctrl and verb == 0:
                want = "sfx"
            if want != vname or (gsup and not (tables.mode & 4)) != bool(sup):
                print(f"CROSS-CHECK FAIL cmd={cmd:#06x} pack={want} "
                      f"sup={gsup} log={vname} sup={sup}", file=sys.stderr)
                mismatch += 1
            if f[col["track"]] != "-" and int(f[col["track"]]) != track:
                print(f"CROSS-CHECK FAIL cmd={cmd:#06x} track", file=sys.stderr)
                mismatch += 1
            run.record(frame, cmd, argw, argb,
                       hs_val=int(f[col["val"]], 0))
    if mismatch:
        raise SystemExit(f"{events_tsv}: {mismatch} pack-vs-log mismatches")
    return run


def parse_phase0(tables: Tables, latch_tsv: Path) -> Run:
    run = Run(tables)
    rows = []
    with open(latch_tsv) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        col = {c: i for i, c in enumerate(header)}
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if f[col["side"]] != "68k_w":
                continue
            rows.append((int(f[col["frame"]]), int(f[col["addr"]], 0),
                         int(f[col["value"]], 0), int(f[col["mask"]], 0)))
    i = 0
    while i < len(rows):
        frame, addr, val, mask = rows[i]
        if mask == 0xffff:
            # trace logs one row per lane: even (high) then odd (low)
            assert i + 1 < len(rows), "dangling word-write row"
            f2, a2, v2, m2 = rows[i + 1]
            assert m2 == 0xffff and a2 == addr + 1 and addr % 2 == 0 \
                and f2 == frame, f"unpaired word write at row {i}"
            run.write_word(frame, addr, (val << 8) | v2)
            i += 2
            continue
        off = addr - tables.latch_page
        if mask == 0x00ff:
            assert off % 2 == 1
            run.write_byte(frame, off, val)
        elif mask == 0xff00:
            assert off % 2 == 0
            run.write_hi_byte(frame, off, val)
        else:
            raise SystemExit(f"unexpected mask {mask:#06x} at row {i}")
        i += 1
    return run


# ---------------------------------------------------------- directed suites ---
def build_directed(tables: Tables) -> Run:
    t = tables
    run = Run(t)
    sup_plays = [c for c, r in enumerate(t.triggers)
                 if r.verb == 1 and r.suppress]
    assert sup_plays, "pack has no suppressed play rows"
    play = sup_plays[0]
    sfx = next(c for c in range(0x20, len(t.triggers))
               if t.triggers[c].verb == 0 and not t.triggers[c].suppress)
    fr = 100

    # boot memtest: full-word fills over the whole page (0x00/0x55/0xff)
    for pat in (0x0000, 0x5555, 0xffff):
        for a in range(0, 0x20, 2):
            run.write_word(fr, t.latch_page + a, pat)
        fr += 1
    # handshake init byte writes with non-pending values
    run.write_byte(fr, t.off_hs, 0x55)
    run.write_byte(fr, t.off_hs, t.hs_ready)
    fr += 1

    # suppressed play -> gate + event
    run.record(fr, play, argw=0x1234, argb=0x56)
    # back-to-back: same command again ONE frame later -> both emit + gate
    run.record(fr + 1, play, argw=0x1234, argb=0x56)
    fr += 3

    # wrong-value handshake write: nothing may happen
    run.record(fr, play, hs_val=(t.hs_pending ^ 0x01) & 0xff)
    fr += 1

    # a suppressed play is latched; now a FULL-WORD write whose low byte is
    # the pending value hits the handshake word -> must pass untouched
    run.write_byte(fr, t.off_cmd_hi, (play >> 8) & 0xff)
    run.write_byte(fr, t.off_cmd_lo, play & 0xff)
    run.write_word(fr, t.latch_page + (t.off_hs & ~1),
                   0xaa00 | t.hs_pending)
    # high-lane byte write to the even neighbour of the handshake byte
    run.write_hi_byte(fr, t.off_hs & ~1, t.hs_pending)
    # read cycle over the handshake word
    run.read_word(fr, t.latch_page + (t.off_hs & ~1), t.hs_pending)
    # same write with cs low (outside the QSound region decode)
    run.write_nocs(fr, t.latch_page + (t.off_hs & ~1), t.hs_pending)
    fr += 1
    # ... the latched suppressed command still gates a proper byte write
    run.write_byte(fr, t.off_hs, t.hs_pending)
    fr += 1

    # unmapped music command (SFX): passes, no gate, no event
    run.record(fr, sfx, argw=0x0001)
    fr += 1
    # command beyond the trigger table: same
    run.record(fr, 0x2345)
    fr += 1

    # control commands: mapped verbs (never gated), then an unmatched one
    for cmd, vb in sorted(t.ctrl_verbs.items()):
        run.record(fr, cmd, argw=0x0200)
        fr += 1
    run.record(fr, t.ctrl_start | 0x7f, argw=0x0100)   # default verb
    fr += 1

    # suppressed stop rows if the pack has them (sfz2al)
    stops = [c for c, r in enumerate(t.triggers) if r.verb == 2][:2]
    for c in stops:
        run.record(fr, c)
        fr += 1
    return run


def build_wofpage() -> Run:
    """CPS1.5: same protocol at latch page 0xF18000 (wof.json)."""
    trig = [TriggerRow() for _ in range(TRIG_ROWS)]
    trig[0x10] = TriggerRow(verb=1, track=5, gain=100, suppress=1)
    trig[0x11] = TriggerRow(verb=1, track=6, gain=100, suppress=0)
    t = Tables(triggers=trig)
    t.latch_page = 0xf18000
    t.ctrl_dflt = 2
    t.ctrl_verbs = {0xff00: 2}
    run = Run(t)
    run.record(100, 0x0010, argw=0xbeef, argb=0x12)   # gated play
    run.record(101, 0x0011)                           # pass-through play
    run.record(102, 0xff00)                           # control stop
    # traffic on the CPS2 page must be ignored under this config
    run._vec(103, 0x618000 + (t.off_hs & ~1),
             (t.hs_pending & 0xff) | ((t.hs_pending & 0xff) << 8), 0b10)
    return run


# Representative CPS1.5 BGM command values for the directed trigger tables.
# slammast are real observed BGM commands (manifests/protocol/slammast.json
# music_range_observed, minus the 0x00f_/0x0113 SFX+section markers); wof has
# no BGM in its attract trace (only control 0xff00), so a small synthetic set
# exercises the driver-1.00 arg-byte-absent config at page 0xf18000.
CPS15_MUSIC = {
    "slammast": [0x0020, 0x00a0, 0x00b0, 0x00d0, 0x01e7],
    "wof":      [0x0010, 0x0011, 0x0012],
}


def cps15_tables(game_id: str) -> Tables:
    """CPS1.5 QSound Tables from the protocols.py descriptor (latch page
    0xf18000).  A few BGM commands map to PLAY+suppress rows; every other
    command defaults to SFX pass-through.  Feeds build_directed so the full
    corner-case battery runs at the CPS1.5 page through the shared RTL tap."""
    proto = P.get_protocol(game_id)
    assert proto.latch_page == 0xf18000, f"{game_id} is not a CPS1.5 descriptor"
    trig = [TriggerRow() for _ in range(TRIG_ROWS)]
    for i, cmd in enumerate(CPS15_MUSIC[game_id]):
        trig[cmd] = TriggerRow(verb=1, track=i + 1, gain=0x60, suppress=1)
    return Tables(proto=proto, triggers=trig)


def build_disabled(pack_path) -> Run:
    t = Tables.from_pack(pack_path, mode=0b000)   # enable = 0
    run = Run(t)
    sup_play = next(c for c, r in enumerate(t.triggers)
                    if r.verb == 1 and r.suppress)
    run.record(100, sup_play, argw=0x1234)
    run.record(101, 0xff00)
    return run


# ------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["all"], help="generate every run")
    ap.add_argument("--outdir", required=True, type=Path)
    args = ap.parse_args()

    runs = []
    for game, paths in GAMES.items():
        pack = CPSPLUS / paths["pack"]
        tab = Tables.from_pack(pack)
        r2 = parse_phase2(Tables.from_pack(pack), CPSPLUS / paths["phase2"])
        r0 = parse_phase0(Tables.from_pack(pack), CPSPLUS / paths["phase0"])
        rd = build_directed(tab)
        runs += [(f"{game}_phase2", r2), (f"{game}_phase0", r0),
                 (f"{game}_directed", rd)]
    runs.append(("wofpage_directed", build_wofpage()))
    # CPS1.5 QSound (jtcps15_cpsplus): same tap RTL at latch page 0xf18000
    runs.append(("wof_directed", build_directed(cps15_tables("wof"))))
    runs.append(("slammast_directed", build_directed(cps15_tables("slammast"))))
    runs.append(("disabled_directed",
                 build_disabled(CPSPLUS / GAMES["sfau"]["pack"])))

    manifest = []
    for name, run in runs:
        p = run.dump(args.outdir, name)
        manifest.append(f"{name} {p['cfg']} {p['trig']} {p['stim']} {p['gold']}")
        print(f"{name:22s} stim={len(run.stim):6d} gold={len(run.gold):4d} "
              f"gates={run.gates:3d}")
    (args.outdir / "runs.txt").write_text("\n".join(manifest) + "\n")
    print(f"wrote {args.outdir}/runs.txt ({len(runs)} runs)")


if __name__ == "__main__":
    main()
