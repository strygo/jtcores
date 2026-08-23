# CPS+ — arranged-audio playback for the CPS cores

CPS+ adds arranged/alternate soundtracks to the JTCPS1, JTCPS15 and JTCPS2
cores on MiSTer.  It taps the game's sound-command latch, suppresses the
native music driver for mapped commands only, and streams byte-exact audio
(CRI ADX or s16le PCM) from a **pack** — a single file appended to the MRA
ROM image and resident in DDR.  SFX, voices and any unmapped command fall
through to the native sound hardware untouched.  With no pack loaded, or
built without the feature, the cores are stock.

```
                 ┌────────────────────────── cpsplus_top ───────────────────────────┐
 68K bus tap ──▶ │ cpsplus_trigger ──evt_*──▶ ┌──────────── cpsplus_ddr ──────────┐ │
      gate ◀──── │        ▲                   │ boot FSM: hdr parse → cfg bank    │ │ ◀─▶ DDRAM
                 │        └── cfg/table load ─│   → trigger BRAM → index BRAM     │ │     (MiSTer)
                 │                            │ verb service: play/stop/fade      │ │
                 │                            │ mem backend: 2×64 B ping-pong     │ │
                 │ cpsplus_player ◀──trk/fade─┘   prefetch                        │ │
 audio_l/r ◀──── │        └──────mem_rd/addr/data/ack────────────────────────────▲┘ │
                 └───────────────────────────────────────────────────────────────────┘
```

## Files

| file | role |
|---|---|
| `hdl/cpsplus_trigger.v` | CPS2/CPS1.5 QSound-latch sniffer + handshake write gate |
| `hdl/cpsplus_cps1_tap.v` | CPS1 byte-latch sniffer + idle-byte substitution |
| `hdl/cpsplus_top.v` | CPS2/CPS1.5 stack wrapper (trigger + ddr + player) |
| `hdl/cpsplus_cps1_top.v` | CPS1 stack wrapper (tap + ddr + player) |
| `hdl/cpsplus_ddr.v` | pack loader + verb service + player memory backend (one DDRAM master) |
| `hdl/cpsplus_player.v` | track playback: fetch → decode → FIFO → volume × fade |
| `hdl/cpsplus_adx.v` | CRI ADX frame decoder (bit-exact vs the pack toolchain) |
| `hdl/cpsplus_dbg_overlay.v` | on-screen diagnostic (CPSPLUS_DBG builds only) |
| `hdl/cpsplus_xf_lut.hex` | Q15 equal-power weights for loop crossfade (`$readmemh`, resolved next to the RTL) |
| `bin/append_pack.py` | append a `.cpk` pack to a ROM image |
| `bin/embed_pack_mra.py` | embed a pack + pack pointer into an MRA |

Deep dives: [doc/TRIGGER.md](doc/TRIGGER.md) (bus protocols, suppression),
[doc/DDR.md](doc/DDR.md) (pack loading, DDRAM), [doc/PLAYER.md](doc/PLAYER.md)
(decode datapath, loop crossfade, volume/fade laws).

## Building

The feature is opt-in per build; everything is gated on the `CPSPLUS` macro
and each core's files.yaml lists this module unconditionally (uninstantiated
modules are pruned).  A build without the macro is the stock core:

```
jtcore cps2  -mister -d CPSPLUS                   # arranged-audio core
jtcore cps1  -mister -d CPSPLUS -d CPSPLUS_DBG    # + on-screen diagnostic
jtcore cps15 -mister                              # stock, zero CPS+ cost
```

## Integration points (all `ifdef CPSPLUS`)

* **Game tops** (`jtcps1_game.v`, `jtcps15_game.v`, `jtcps2_game.v`):
  instantiate the per-family `cpsplus_*_top`, mux the arranged audio into
  the core mixer, and gate/substitute the sound latch.  The CPS1 tap
  substitutes an idle byte into `snd_latch0`; the QSound trigger gates the
  shared-RAM handshake write's byte lane (one wire: `main_ldswn | gate`).
* **jtframe MiSTer target**: a read-only DDR client on `jtframe_mr_ddrmux`
  (lowest priority), and the OSD entry `Arranged volume`
  (100% / 125% / 150% / 75%, status bits 15:14, boost steps saturate).
* **MRA**: the pack is appended to the `<rom index="0">` image;
  `<patch offset="8">` stores the pack pointer (little-endian u16, 1 kB
  units).  `bin/embed_pack_mra.py` writes both and verifies the pointer
  against the real ROM length.  A wrong pointer fails open — the core
  boots stock (and the debug overlay shows RED).

## Debug overlay (`-d CPSPLUS_DBG`)

A 16×16 square at (8,8) in active pixels encodes the pack-load state —
GREEN playing, BLUE loaded/idle, YELLOW loading, RED no pack pointer,
MAGENTA bad magic, CYAN header out of range.  RED/MAGENTA indict the MRA,
not the core.  Below it, eight 8-px cells show the last non-idle sound
command (MSB left) and a ninth cell shows whether the pack maps it (green)
or it fell through to the native chip (red).  The overlay lives in the
video clock domain and resyncs everything it samples; it costs no timing
(all indexing is shifts — no divides in the pixel path).

## Testbenches (`ver/`)

`tb_dbg_overlay.v` and `tb_vol_saturate.v` are self-contained
(`iverilog tb_x.v ../hdl/<dut>.v`).  The trigger / tap / player / ddr /
full-chain suites replay validated bus traces and compare against the pack
toolchain's software oracles; their vector generators (`gen_*.py`) require
the CPS+ pack workspace and real packs, which live outside this repository.
The suites and their pass criteria are documented in the doc/ deep dives —
they are the acceptance record for this RTL (headline: full-chain PCM
divergence 0 over 690,000 sample pairs against the software renderer).

## Fail-open invariants

Every failure mode leaves the host core stock: no pack pointer, bad magic,
header out of range, OSD off, or no `CPSPLUS` macro at all.  `MODE.enable`
is the last word the loader writes, and the trigger's reset default is
disabled.  Known limitation: the loader validates magic and header bounds
but not the pack CRCs; a corrupted-but-well-formed pack plays corrupted
audio rather than failing open.
