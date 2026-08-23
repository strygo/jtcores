# CPS+ command sniffers: `cpsplus_trigger` + `cpsplus_cps1_tap`

The bus-tap half of CPS+ (module overview: [../README.md](../README.md);
loader/player: [DDR.md](DDR.md), [PLAYER.md](PLAYER.md)).  Verilog-2005,
Quartus-synthesizable, no vendor primitives.

Everything game-specific is data: latch page, field offsets, handshake
offset/values, control region and verb map come from a config register
bank; the trigger table is a loadable BRAM.  New game = new pack, zero RTL
changes.

## cpsplus_trigger

Passive tap on the 68K side of the QSound shared-RAM latch page.  Latches
record bytes as they stream in; on the handshake write (`+0x1f ← pending`)
classifies the 16-bit command through the pack trigger table (BRAM,
direct-mapped, 4-byte rows of the pack binary layout, v0) and the
header control-verb map, then:

- emits a **verb event** for the player — `evt_stb` strobe with
  `evt_verb` (1 play … 6 master_fade), `evt_track[11:0]`, `evt_gain[6:0]`,
  `evt_argw[15:0]`, `evt_argb[7:0]`, `evt_ctrl`, `evt_sup`;
- for suppress-flagged rows asserts `gate` for the duration of that
  handshake write so the integration mux blocks the shared-RAM write
  enable for that byte lane only.  The write itself is gated — nothing is
  ever re-poked; the Z80 keeps seeing the last "ready" byte and never
  wakes up, the 68K's readiness poll still reads ready
  (validated end-to-end in MAME).

Everything game-specific is data: the latch page, field offsets,
handshake offset/values, control region and verb map come from a config
register bank; the trigger table is a loadable BRAM.  New game = new pack,
zero RTL changes.  Absent fields (e.g. HSF2 1.06b has no `+0x05` arg byte)
are encoded as offset 0, which can never match an odd latched offset — no
special casing.  A config MODE bit reserves a future CPS1 single-byte-latch
dialect (0x800180 latches, no handshake); v0 implements the record dialect
shared by CPS2 and CPS1.5.

### Protocol qualification (what counts as a handshake write)

Record fields and the handshake byte live on odd byte addresses = the low
byte lane (`LDSWn`) of the big-endian 68K bus.  A handshake write is
accepted only as a **pure low-lane byte write** (`dsn == 2'b10`) of the
configured pending value to the configured offset.  Full-word writes never
qualify: the boot memtest sweeps the page with word fills (0x0000 / 0x5555
/ 0xFFFF) and passes untouched by construction (byte-lane + value
qualification).  Record-byte latching accepts the low lane of both byte
and word writes, matching the software prototype.

Classification is pre-computed: whenever a command byte latches, the BRAM
row and control map are re-evaluated into registers (3 clk settle,
`lut_valid` guard).  The handshake write is always a separate, later 68K
bus cycle (record-then-handshake held across ~3000 records, 23 sets, 6
captured driver revisions), so by the time it appears the suppress
decision is already registered and `gate` is a shallow combinational
term of the live bus qualifiers — it covers the write from its first clk.
Control commands (≥ `control_region_start`) are never suppressed.
Back-to-back records on consecutive frames are independent lookups; both
emit (real case: sfz2al writes suppressed stops on consecutive frames,
sfau attract plays 0x0022/0x0023 one frame apart — both in the TB).

### Integration contract for jtcps2_game.v

Tap the existing nets and cut ONE
wire — the `LDSWn` input of the sound module:

```verilog
wire trig_gate;

cpsplus_trigger u_trigger (
    .rst   ( rst           ),
    .clk   ( clk           ),   // 96 MHz master, same domain as u_sound
    .cen   ( 1'b1          ),
    .addr  ( main2qs_addr  ),   // registered in jtcps2_main, stable per cycle
    .dout  ( main_dout     ),
    .dsn   ( dsn           ),   // {UDSWn, LDSWn}
    .rnw   ( main_rnw      ),
    .cs    ( main2qs_cs    ),   // 0x600000-0x61FFFF decode; the module
                                // narrows to the configured 32-byte page
    .gate  ( trig_gate     ),
    /* evt_* -> cpsplus_player, cfg/trig ports -> pack loader */ );

// jtcps15_sound instance: the ONLY core-side edit is this input mux
-   .main_ldswn ( dsn[0]             ),
+   .main_ldswn ( dsn[0] | trig_gate ),
```

Inside `jtcps15_sound`, `bus_wrn = main_busn ? wr_n : main_ldswn` and
`ram_we = ram_cs && !bus_wrn`: forcing `main_ldswn` high for the gated
cycle blocks exactly that byte's write enable.  Z80-side accesses
(`main_busn==1`) mux from `wr_n`, so the gate can never affect the Z80.
Nothing else in the core changes; with no pack loaded (`MODE.enable=0`,
the reset default) `trig_gate` is constant 0 and the core is stock.

Waveform of a suppressed handshake write (68K bus cycle, many clk long):

```
clk          ¯\_/¯\_/¯\_/¯\_/¯\_/¯\_/¯\_/¯\_/¯\_/¯\_
main2qs_cs   ____/¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯\____
dsn[0]       ¯¯¯¯\____________________________/¯¯¯¯   68K byte write, low lane
dsn[1]       ¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯   (byte, not word, write)
addr/dout    ====X page+0x1e / xx00 (pending)  X====
gate         ____/¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯\____   combinational, full cycle
ldswn|gate   ¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯   sound module sees no write
evt_stb      _____/¯\______________________________   1 clk, second cycle
```

`gate` spans every clk of the qualified write because its slow terms
(`cls_sup`, `lut_valid`) were registered when the command bytes latched —
there is no lookup on the critical path.  The Z80 bus grant inside
`jtcps15_sound` (busrq/busak) adds further clks of margin before `ram_we`
can first sample.  Timing assumptions on the tap: bus inputs stable for
the whole 68K cycle, and strobes deassert for ≥1 clk between cycles —
both true of the jtcps2_game nets.

For CPS1.5 (wof etc.) the same module is instantiated in the CPS1.5 game
top with that core's QSound region select; the pack sets
`latch_page = 0xF18000`.  Same protocol, verified by the `wofpage` TB.

### Config / table loading

Who fills the BRAMs: a future **pack loader** module (companion to the DDR
player path).  The pack rides the MRA ROM image into DDR at 0x30000000; at
boot (and on OSD pack toggle) the loader reads the 4 KB header + 18 KB
trigger table over the same DDR port the player uses, then writes:

- `cfg_we/cfg_addr/cfg_data` — protocol descriptor registers:
  `0x00/0x01` latch page, `0x02` cmd offsets, `0x03` arg-word offsets,
  `0x04` {handshake, arg-byte} offsets, `0x05` {ready, pending} values,
  `0x06` control region start, `0x07` MODE
  (bit0 enable, bit1 reserved cps1 dialect, bit2 observe-only/no-gate,
  bits6:4 control default verb), `0x40+2i`/`0x41+2i` control map entry i
  (cmd, verb), zero-filling unused entries;
- `trig_we/trig_addr/trig_data` — 0x1200 table rows as little-endian
  32-bit words straight from the file.

MODE.enable is written last; reset default is disabled = stock core.  In
the TB the loader is modeled by the `tb_trigger.v` load loops fed from
hex images that `gen_trigger_vectors.py` extracts from real `.cpk` packs
via `pack/format.py` (the normative layout reader).

### Running the testbench

```
cd modules/cpsplus/ver
make trigger        # generate vectors, compile (iverilog -g2005), run all
```

Requires Icarus Verilog (tested 13.0) and the CPS+ pack workspace (real
packs, captured 68K byte-lane traces including the boot memtest, and the
validated prototype event logs — not in this repository).  Suites (11, all must PASS):

- `{sfau,hsf2,sfz2al}_phase2` — replay of the captured fight logs;
  emitted verb sequence must equal the validated prototype's, frame-
  accurately, and `gate` must assert exactly on the suppressed commands'
  handshake writes (sfau exercises the re-keyed −0x38 pack, hsf2 the
  absent `+0x05` field, sfz2al suppressed stop rows).
- `{sfau,hsf2,sfz2al}_phase0` — replay of raw captured latch traces
  (memtest word fills, 0x55/0xFF init patterns, even-lane writes) against
  a reference model port of the prototype.
- `{sfau,hsf2,sfz2al}_directed` — corner cases: back-to-back plays 1
  frame apart, full-word write to the handshake word with a suppressed
  command latched (must pass untouched), wrong-value / wrong-lane
  handshake writes, read cycles, `cs=0` writes, control verbs with fade
  args, unmatched control commands, unmapped (SFX) and out-of-table
  commands.
- `wofpage_directed` — CPS1.5 latch page 0xF18000 config; CPS2-page
  traffic must be ignored.
- `disabled_directed` — MODE.enable=0: suppressed plays produce no
  events, no gate.

The TB checks were mutation-tested (dropping the word-write
qualification, killing the gate, corrupting track assembly — each is
caught by the corresponding suite).

## cpsplus_cps1_tap (CPS1 byte latch)

CPS1 (jtcps1: Z80 + YM2151 + OKI, **not** QSound) has no shared RAM and no
handshake — the 68K drops a single command byte into a fire-and-forget
register latch (`$800181` = jtcps1 `snd_latch0`) that the Z80 polls.
`cpsplus_cps1_tap` is the CPS1 sibling of `cpsplus_trigger`: it snoops that
latch, classifies the **8-bit** command through the same 4-byte pack trigger
rows (a 256-row table) + control-verb map, and drives the identical `evt_*`,
`cfg_*` and `trig_*` ports, so `cpsplus_ddr` and `cpsplus_player` are reused
with no change (`cpsplus_cps1_top` wraps the three; `cpsplus_top` /
`cpsplus_trigger` stay untouched).

Two things differ from the QSound sniffer:

* **Suppression is a value substitution, not a bus-write gate.** For a
  `suppress`-flagged music command the tap raises `sub` for as long as that
  value sits in the latch; the game top substitutes the configured idle byte
  (`0xff`, from the descriptor's `handshake_ready` -> `hs_ready`) into the
  `snd_latch0` the sound CPU reads, so the Z80 sees an unbroken run of `0xff`
  (a terminator) and never starts the native music.  SFX / voices and the
  `0xf0/0xf7/0xff` control family pass through unchanged (`control_region_start = 0x00f0`).

* **The event is the latch value changing**, not a separate handshake write.
  `snd_latch0` (clk48) is resynced into the 96 MHz domain (2-FF + 3-clk
  stability filter), and a new stable value is the CPS1 analogue of the
  handshake strobe.  Classification then settles 3 clk (`lut_valid`) exactly
  as in `cpsplus_trigger`; `sub` and the event assert ~5 clk after the 68K
  posts the command — always far ahead of the Z80's much slower poll (the
  CPS1 analogue of "the handshake write is a later bus cycle").

The pack's `sf2` protocol descriptor (pack toolchain, `protocols.py`) is byte-latch
shaped: `latch_page = 0x800180`, single command byte at `+0x01`, no record
args, no handshake, `fade_law = FADE_NONE` (no sf2 fade-arg law — the fade
latch `$800189` is a separate channel, not wired to the player),
`handshake_ready = 0xff` (the substituted idle byte), `control_region_start
= 0x00f0`, empty control map.

### Running the CPS1 testbench

```
cd modules/cpsplus/ver
make cps1        # generate vectors, compile tb_cps1_tap, run all suites
```

Self-contained (no `work/` artifacts needed): `gen_cps1_vectors.py` builds
the tables from the pack toolchain's protocol descriptors and replays the
validated sf2 captured latch-trace slice (first 64 command events).
Suites (4, all PASS, divergence = 0 vs the software reference):

- `sf2_trace` — real attract+demo trace (boot/title/select/Guile-stage
  music + SFX + voices + control): the emitted verb sequence and the `sub`
  level per command match the reference.
- `sf2_directed` — every verified music command (PLAY + suppress), a
  suppressed STOP row, an SFX pass-through, back-to-back distinct music, the
  same music twice with an idle between (both re-fire), and control/voice
  pass-through (no event, no `sub`).
- `sf2_nogate` — MODE.nogate=1: events still emitted, `sub` masked
  (observe-only: audition arranged over native music).
- `sf2_disabled` — MODE.enable=0: no events, `sub` never asserts (stock
  core, the reset default).
