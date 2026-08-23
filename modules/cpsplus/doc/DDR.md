# CPS+ pack loader / DDR backend: `cpsplus_ddr` + `cpsplus_top`

The pack-loading and DDRAM half of CPS+ (sniffers: [TRIGGER.md](TRIGGER.md),
playback: [PLAYER.md](PLAYER.md)), plus the thin `cpsplus_top` wrapper a game
top instantiates.  Verilog-2005, Quartus-synthesizable, no vendor primitives.
Verified under Icarus Verilog 13.0 — unit TB plus a full-chain acceptance run
against the real HSF2 Arrange pack (§Testbenches).

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

## cpsplus_ddr

One module, three services, one DDRAM master presented upstream.

### 1. Boot loader

`boot_go` (pulsed by the integration after the ROM fast-load finishes, or
on a pack switch) runs:

1. **Disable first** — config write `MODE = 0` + player stop: stock core
   behavior while (re)loading.  Waits for any in-flight prefetch burst to
   drain before claiming the burst engine.
2. **Base resolution** — `base_indirect=0`: `base_addr` is the pack base.
   `base_indirect=1` (the MiSTer delivery): `base_addr` is the MRA ROM
   image base (0x30000000); the loader reads image bytes 8-9 (reserved
   slot of the CPS MRA start-pointer header, little-endian, 1 kB units)
   and uses `pack_base = base_addr + (ptr << 10)`.  `ptr` 0x0000/0xFFFF
   (the header fill values) = no pack appended → status 4, stay disabled.
3. **Header** — one 37-word burst (bytes 0x000..0x127 of the pack,
   the pack binary layout, v0).  Magic != "CP2A" → status 5,
   **fail open** (module quiescent, trigger stays disabled, core stock).
   Captures section offsets, the protocol descriptor, fade law +
   constants (latched on the player-facing `fade_law/fade_const*`
   outputs — the trigger does not need them) and
   the ≤32-entry control-verb map.
4. **Config bank** — 71 writes to the trigger config port: registers
   0x00..0x06, then all 64 control-map words (zero-filled beyond the
   pack's count).  Register map exactly as TRIGGER.md §Config / table loading.
5. **Trigger table** — streamed in 32-word bursts through a chunk buffer
   (a 64-bit DDR word = two little-endian 4-byte rows), then zero-fill up
   to the full 4608 rows so a smaller pack never inherits stale rows.
6. **Track index** — `min(track_count, 2^TRK_AW)` 32 B entries streamed
   into the internal index BRAM (64-bit × 4 words per track; 4 KB at the
   default 128 tracks).  Stale entries beyond a new pack's count are
   harmless: packs are `verify()`-validated so no trigger row references
   a track ≥ count.
7. **`MODE` written LAST** (trigger README contract), with
   `enable = osd_en` and the header's control-default verb; `ready` set.

After boot, `MODE.enable` follows `osd_en`: toggling off rewrites MODE
and stops the player; toggling back on is a single config write (the pack
stays loaded).  `boot_go` while ready reloads (pack switch).

### 2. Verb service (trigger `evt_*` → player)

| verb | action |
|---|---|
| 1 play | 4 index-BRAM reads → `trk_*` register outputs (`trk_addr = pack_base + header.data_offset + entry.data_offset` — absolute DDR byte address, per PLAYER.md) + `pl_start` pulse.  8 clk total, within the trigger's ≥12 clk event spacing. |
| 2 stop | `pl_stop` pulse |
| 3 fade_out | `fade_trig` + `fade_loop_off` |
| 4 fade_keep | `fade_trig` |
| 5 restore | `restore_trig` |
| 6 master_fade | `fade_trig`, target forced 0 |

Fade target = `min(evt_argb*4, 127)` (the PS2 arg-byte ×4 clamp);
`fade_arg = evt_argw`.  The trigger emits the raw `evt_argb`; the ×4 clamp
lives here, not in the trigger.  Plays referencing a track ≥ capacity or ≥ the pack's count are
ignored (cannot happen with a verified pack).

### 3. Player memory backend

Implements the PLAYER.md memory-port contract (rd held with stable
`addr[31:3]` until a single-cycle ack with the little-endian 64-bit word;
one outstanding) with a 128-byte ping-pong prefetcher:

* two 64 B buffers (8 words each) with word-address tags;
* **miss** → 8-word DDRAM burst from the requested address, ack on the
  first beat (subsequent hits served as beats land), other buffer
  invalidated (covers loop wraps and restarts);
* **prefetch ahead** — serving a hit past the middle of a buffer fetches
  the next 64 B into the other buffer in the background, so the player's
  sequential pattern (PLAYER.md: jumps only at wraps/restarts) never
  waits on DDR after the first word;
* a miss while `loading` or `!ready` returns a **dummy zero ack** so the
  player's stop-drain can never deadlock during a pack switch (the stop
  discards the data).

Sustained demand is one word per ~14 µs (48 kHz stereo ADX); a 8-word
burst takes < 1 µs, so headroom is ~100×.

### DDRAM protocol

As `jtframe_mister_dwnld.v` / `jtframe_lfbuf_ddr_ctrl.v`: assert
`ddram_rd` with addr/burstcnt and hold while `ddram_busy`; accepted on
the first !busy cycle; exactly `burstcnt` `ddram_dout_ready` beats follow.
`ddram_addr` is the 64-bit-word address (byte >> 3).  Boot and prefetch
never overlap (see boot step 1), so a single engine serializes all use —
the arbitration is structural, not a mux race.

## cpsplus_top

Pure wiring: trigger ⇄ ddr (evt + cfg/table load), ddr ⇄ player
(trk/fade/start/stop + mem port), one DDRAM master out, the 68K bus tap
in, `gate` out.  Everything clocks on the 96 MHz master clock (same
domain as `jtcps15_sound` and the DDRAM port).  `cen_sample` must tick at
the current track rate — the integration drives a
`jtframe_frac_cen #(.WC(27))` with `n = trk_rate, m = 96e6` (exact for
any rate; multi-rate packs switch per track via the `trk_rate` output,
so mixed-rate packs work).  `cen_frame` = LVBL edge.
With no pack / bad magic / OSD off / no `boot_go`, `gate` is constant 0
and the host core is stock.

## Testbenches (run `make -f Makefile.ddr` from ver/)

Vectors come from `tb/gen_chain_vectors.py`, which reuses the
gen_trigger_vectors.py machinery (protocol/table extraction + the
reference classifier) and the pack toolchain oracles (`format.py`
writer/reader, `audition.py` render — CPS+ pack workspace).

### tb_ddr — unit acceptance (3 runs, all PASS)

Backed by a tiny synthetic pack written by `pack.format.PackWriter` (the
normative layout writer) behind a 64 B MRA-header stub:

* boot: pointer dereference; **all 72 trigger config words bit-exact** vs
  the `Tables.cfg_words` golden; **all 4608 trigger rows bit-exact**
  (incl. zero fill); MODE.enable written once, last, never before the
  tables; fade law/constants latched;
* fail-open: corrupted magic (status 5) and 0xFFFF pointer (status 4) —
  ready never set, no MODE.enable write, dummy acks;
* verb service: both tracks' `trk_*` registers exact (address/len/loops/
  channels/codec/gains/coefs/rate), stop/fade/fade-keep/restore/
  master-fade mapping incl. the argb×4 clamp both below and above 127;
* memory backend: sequential/wrap-jump/far-jump reads byte-exact with
  single-cycle acks;
* OSD off/on rewrites + player stop; reboot (pack switch) to ready again.

### tb_chain — full-chain acceptance (PASS)

`cpsplus_top` (trigger + ddr + player, the real RTL of all five modules)
against a behavioral MiSTer DDRAM model (random busy, burst latency and
inter-beat gaps) backed by the REAL HSF2 Arrange pack,
**windowed**: 64 B MRA stub (pack pointer = 1 kB) + the pack's header /
trigger table / track index verbatim + ONE track's data — track 54
(`arg_37.adx`, the smallest looped track) — relocated by patching that
index entry's `data_offset` to 0 so the 184 MB pack windows to 792 KB.
Other tracks keep their original out-of-window offsets and read as
zeros, which makes the log's preceding track-53 play stream silence and
exercises a mid-play restart through the backend.

Stimulus = the validated hsf2 fight log, frames 5509–6350, reconstructed as 68K bus cycles: driver stop/init
control records, the suppressed plays 0x0036→t53 and 0x0037→t54, 11 SFX
records spread over playback, plus an injected HSF2-law fade
(0xff06, argw 0x0444) after the loop wrap and the driver-style stop
(0xff00) mid-fade.  Bus vectors carry collected-pair thresholds so the
fade/stop land at exact stream positions.

| check | result |
|---|---|
| boot via MRA pointer + full pack load | ready in 9,278 cycles, magic ok |
| `gate` on exactly the suppressed handshake writes | pass (monitor) |
| verb-event sequence (stop, play 53, play 54, fade_keep, stop) vs pack classification | 5/5 exact |
| PCM vs `audition.render` × exact volume law (vol_q14 = 13416) | **690,000/690,000 pairs, divergence = 0** |
| ≥1 loop wrap inside the compared window | wrap at pair 681,696 (predictor snapshot/restore through the real backend) |
| fade engine after the chain-delivered verb | frames=60, step=139810, target=0 — exact |
| stop mid-fade | silence + playing=0 + no further samples |

Runtime ≈ 80 s vvp (TICK=8 clk/sample, FDIV=100).

## Interface notes (trigger/player fit)

No mismatches required glue-level adaptation.  Two doc-level notes:
the fade-target ×4 clamp is implemented here, not in the trigger (see
§Verb service); and the trigger README's "route fade-law constants to the
player via the loader" is exactly what `fade_law/fade_const1/2` do.

## Known limitations

* **CRC check** — the loader validates magic and header bounds but not the
  pack CRCs (boot-time cost); a corrupted-but-well-formed pack plays
  corrupted audio rather than failing open.
* **DDR window >4 GB guard** — the header data_offset high word must be 0
  (status 6); fine for ≤240 MB packs.
* **Vertical games** — the ddrmux grant gives video priority; a CPS2
  vertical game actively rotating starves the CPS+ client.  Packs target
  horizontal games.

Fitter facts (Cyclone V 5CSEBA6, measured): the full CPS+ stack costs
~3.5k ALMs and 54–76 M10K per core; no CPS+ node lands on a violating
timing path — everything is registered short-hop logic at 96 MHz.
