# CPS+ audio datapath: `cpsplus_adx` + `cpsplus_player`

The decode/playback half of CPS+ (sniffers: [TRIGGER.md](TRIGGER.md),
loader/DDR: [DDR.md](DDR.md)).  Verilog-2005, Quartus-synthesizable, no
vendor primitives.  Verified under Icarus Verilog 13.0 against the real
HSF2 Arrange pack — see §Testbenches.

```
cpsplus_trigger ──start/stop/fade──▶ ┌──────────────────────────────────┐
                                     │ cpsplus_player                   │
DDR client ◀──mem_rd/addr/data/ack──▶│  word fetch → byte serializer    │
                                     │  → cpsplus_adx / PCM passthrough │
                                     │  → 256-pair FIFO (1 KB BRAM)     │
                                     │  → cen_sample drain              │
                                     │  → volume × fade multiply        │──▶ audio_l/r
                                     └──────────────────────────────────┘
```

## cpsplus_adx — CRI ADX frame decoder

Decodes header-stripped ADX frame streams exactly as stored in `.cpk`
packs: 18-byte frames = 2-byte **big-endian** scale word +
16 nibble bytes = 32 samples per channel.  Stereo interleaves one L frame
then one R frame (36-byte frame group); the decoder emits L/R **pairs**
(mono mirrors L into R).

**Arithmetic — ffmpeg convention, bit-exact vs the pack toolchain's
`adxcodec.py` `py_decode`** (the convention holder; `scale`, *not* the
multimedia.cx `scale+1`):

```
d   = nibble as signed 4-bit, high nibble of each byte first
s0  = d*scale + ((c1*s1 + c2*s2) >>> 12)     # one arithmetic shift, on the sum
out = clip16(s0);  s2' = s1;  s1' = clip16(s0)   # both taps post-clip
```

c1/c2 come precomputed from the pack track index (ffmpeg lrint variants) —
the RTL never parses stream headers.  A frame whose scale MSB is set (CRI
EOF frame — packs are validated to contain none) is consumed without
emitting samples and flagged on `eof`; the player defensively ends the
track.

Interface: byte-stream valid/ready in, sample-pair valid/ready out,
`clr` (history+assembly clear), `busy` (frame group in flight), and the
predictor history port — `hist_out = {s1_l,s2_l,s1_r,s2_r}` continuously,
`hist_load` (only while `!busy`) overwrites from `hist_in`.  Throughput:
3 clk/sample pair after an 18/36-clk collect (~150 clk per 32 stereo
pairs) — decode never limits any audio rate.  Cost: 3 16×16 multipliers
(shareable later if DSPs get tight), 36-byte assembly buffer, no BRAM.

## cpsplus_player — track playback datapath

mdp_audio heritage, with the ring-buffer
flow control replaced by direct DDR-resident track addressing + in-stream
loop wraparound, per the pack contract.

**Track index register set** — latched from `trk_*` inputs on the `start`
pulse (absolute stream address, length, loop start/end bytes, channels,
codec, gain, c1/c2, plus the trigger row gain).  Inputs are free to change
after the pulse.  Loop sample fields are not needed (byte fields are the
authoritative wrap points).  The sample rate is not
consumed here: `cen_sample` (frac-cen at the track rate) and `cen_frame`
(~60 Hz, fade stepping) come from outside.

**Feed FSM** (IDLE/FETCH/FEED/SNAP/WRAP): fetches 8-byte words through the
abstracted memory port, serializes bytes to the codec.  Boundaries are
byte-exact: after feeding byte `pos`,

* `pos == loop_start` (first time, looped ADX only): pause, wait for the
  decoder to drain (`!busy`), latch `hist_out` — the predictor state
  *entering* the loop-start frame.  `loop_start == 0` snapshots are the
  zero-history stream head (pre-initialized, no wait).
* `pos == loop_end` with looping enabled: wait `!busy`, pulse `hist_load`
  with the snapshot, jump back to `loop_start`.  Legal because pack
  `verify()` enforces frame-group alignment of both loop bytes.
* `pos == loop_end` with looping off (verb 3), or `pos == len` for
  non-looping tracks: feed done → FIFO drains → `track_done`.

PCM s16le passthrough (codec 1) uses a 2/4-byte assembler instead of the
decoder; wrap alignment is guaranteed by the same pack validation, and no
history is involved.

**Loop crossfade** (`trk_xfade_en`, pack layout v1).  For a crossfade
track the stored stream keeps `XFADE_N` samples of natural continuation past
loop_end (the "tail").  Two small changes make the loop seamless with no
re-encode:

* *Feed FSM* — the snapshot/wrap point moves by the tail length: the feed
  decodes through loop_end into the tail [loop_end, loop_end+N), snapshots
  the predictor state entering loop_start+N, then wraps the read pointer to
  loop_start+N.  Steady-state loop period stays loop_end−loop_start and the
  memory address path is unchanged (only the constants loaded into
  `cur`/`pos` differ).
* *Output stage* — a `dpos` counter mirrors the feed's stream position of
  the FIFO head.  On the first pass the first N loop-body samples
  [loop_start, loop_start+N) (the "head") are captured into a small BRAM;
  each tail sample [loop_end, loop_end+N) is then equal-power blended with
  the matching head sample, `out[k] = w_out(k)·tail + w_in(k)·head`, using a
  Q15 cos/sin LUT (`XF_LUT_FILE`, built by the fitter for `XFADE_N`).
  `trk_xfade_en=0` is bit-identical to the hard-cut loop.  `XFADE_N` MUST
  equal the pack header `xfade_samples`.  Software model: the pack toolchain's `xfade.py`.

  The blend is a **pipeline** so no long combinational chain reaches the audio
  path (fitter closure): (A) registered window flag + LUT/head indices — the
  window boundaries loop_end+N, loop_start+N, loop_end+N−1 are precomputed as
  registered constants at track load, so the per-cycle logic is a compare
  against a constant, never a live add; (B) registered LUT weight + head-buffer
  reads; (C) registered products (two DSP mults/channel); (D) registered
  accumulate + round + shift + clip → `blend_l/r`.  Stage E registers the
  output-select mux (`fl_q = in_tail ? blend : raw head`) BEFORE the volume
  multiply, so the mux and the multiply do not share a clk96 cycle — the mult
  is then the same short path as the stock hard-cut output.  Because the audio
  is only sampled on the ~2000-clk sample tick — during which `dpos`/`fq` are
  frozen — the added latency settles long before each tick and shifts nothing
  in the output stream (golden unchanged).  (The `fl_q` register lags `fq` by a
  cycle, which the delivered stream only notices if the FIFO underruns; that
  never happens at the real ~2000 clk/pair tick, and the PCM stress vector runs
  `TICK=12` — above its ~8.75 clk/pair feed rate — like `fade1`.)

**FIFO + prefill**: 256 sample pairs × 32 bit = 1 KB (one M10K), the only
BRAM in the module (the DDR-side burst FIFO belongs to the DDR client).
Output stays muted until 128 pairs are buffered (or the feed already
finished) — ~2.7 ms at 48 kHz, in line with the MD+ prefill idea but
level-triggered instead of timed.  Underrun (only possible if the DDR
client stalls) outputs silence without consuming golden samples and
recovers gracefully.  The head read is registered with a write-through
bypass for the push-into-empty case, so a pop one cycle after the first
push never sees a stale head.

**Restart/stop**: `start` at any moment re-latches and re-arms; an
in-flight memory read is drained (ack discarded) before the datapath
resets, so back-to-back starts — tested 1 frame apart and 3 clocks
apart — are clean and bit-exact from sample 0.  `stop` clears the output
registers on the spot (silence within the same tick) and parks the feed.
`osd_pause` freezes drain, output and fade stepping.

**Volume law** (v0, linear /127), exact:

```
vol_q14   = floor(((trig_gain * trk_gain) << 14) / 16129)    # at start
total_q14 = (vol_q14 * fade_lvl_q15) >> 15                   # registered
out       = (pcm * total_q14) >>> 14                         # per sample
```

0x7f × 0x7f at full level gives vol_q14 = 16384 → bit-transparent
passthrough.  The one division runs on a shared 32-cycle sequential
restoring divider (also used by the fade engine; ~100 LEs, no DSP).

**Fade engine** — laws and constants are pack-header config: law 1 Anthology `frames = const1/arg` (0xffff/arg), law 2
HSF2 `frames = (const1/arg) × const2` (0x444/arg × 60), `arg = 0` treated
as 1, law-1 zero quotient clamped to 1 frame.  `fade_target` is the record
volume convention 0..0x7f (upstream maps the PS2 arg-byte ×4 clamp);
internally Q15 with `target_q15 = target×258` (127 → exactly 32768) and
8 fractional guard bits on the level.  Per command the engine computes
`step = floor(|level−target|·2^8 / frames)` (divider), then steps once per
`cen_frame` and **lands on the target exactly** on the last frame — no
accumulation drift.  Fades ramp in either direction; `restore_trig` ramps
to unity over RESTORE_FRAMES (8).  Completion at level 0 auto-stops the
track (matching the PS2 driver semantics); `fade_loop_off` (verb 3) clears the
loop switch so the track ends at the next `loop_end` arrival regardless of
the fade target.

**Memory port contract** (what the DDR client must implement):
`mem_rd` held high with stable `mem_addr[31:3]` until a single-cycle
`mem_ack` returns the 8-byte little-endian word (byte at address
`{A[31:3],k}` = `mem_data[8k +: 8]`, matching MiSTer DDRAM_DOUT).  One
outstanding request; the player re-requests per word — burst prefetch,
reordering and the burst FIFO are the client's business.  Sustained
demand: 48 kHz stereo ADX = 54 KB/s ≈ one word per 14 µs; latency is
absorbed by the 1 KB FIFO (≈2.7 ms at the prefill threshold).

## Testbenches (run `make -f Makefile.player` from ver/)

Vector generators (Python) derive **all** stimuli and goldens from the pack
toolchain's `adxcodec.py`, `format.py` and `audition.py` (CPS+ pack
workspace — the same oracles the toolchain is validated with) plus exact integer mirrors
of the RTL volume/fade laws.  Generated vectors and sim builds live under
`work/` (untracked).

| run | source | proves | result |
|---|---|---|---|
| adx t55 | REAL pack track 55, whole track | decoder vs `py_decode`, 112,640 pairs | divergence = 0 |
| adx t0/t54 | tracks 0/54, 2000 frame groups each | same, other content | divergence = 0 |
| p loop | REAL track 54, golden = `audition.render` intro + 2 loop passes | end-to-end datapath incl. **predictor snapshot/restore across both wraps**, 1,616,672 pairs | divergence = 0 |
| p restart | track 54, restart after 800 pairs + racing double start | clean re-arm, bit-exact from sample 0 (40,000 pairs) | divergence = 0 |
| p stop | track 54, stop at 5000 pairs | silence within one tick, no stray samples | pass |
| p monoadx | synthetic mono ADX, loop_end mid-stream | mono decode + wrap not at EOF (208,000 pairs) | divergence = 0 |
| p pcm | synthetic stereo PCM, gain 0x40×0x7f, TICK=12 (feed-rate-safe) | passthrough + exact volume law (68,000 pairs, vol_q14 = 8256) | divergence = 0 |
| p pcm_mono | synthetic one-shot mono PCM | drain → `track_done` at exactly the last sample | pass |
| p fade1 | Anthology law, render_route self-test values | frames 31/8/85, steps 134243/520192/98689, exact landings, steady outputs 8062/16000, fade-to-0 auto-stop | pass |
| p fade2 | HSF2 law | frames (0x444/0x444)×60 = 60 down and **up**, loop-off ends track at loop_end sample 20000 exactly | pass |
| p xfade | synthetic stereo ADX loop-with-tail, N=256, golden = `pack/xfade.py` | **loop crossfade** vs software equal-power ref: first seam (pass 0) + 2 steady loop seams + predictor snapshot/restore at loop_start+N (16,640 pairs) | divergence = 0 |
| p xfade7200 | same at production N=7200 (TB built `-Ptb_player.XFADE_N=7200`) | crossfade datapath + LUT at the real crossfade length (73,024 pairs) | divergence = 0 |

The hard-cut regression is the whole rest of the table run unchanged with
`trk_xfade_en=0`: divergence stays 0, so the crossfade-disabled path is
bit-identical to the pre-crossfade player.

Both testbenches inject pseudo-random (seeded, deterministic) stalls:
byte-valid/sample-ready duty cycling in tb_adx, 3–10-cycle memory latency
in tb_player.

## Contract notes (implemented by `cpsplus_ddr` / the integration)

* The §Memory-port contract is implemented by `cpsplus_ddr`'s 128-byte
  ping-pong prefetcher (the player's address pattern only jumps at loop
  wraps and restarts, which the backend invalidates on).
* `cen_sample` is a `jtframe_frac_cen` at the track's own rate — the
  `trk_rate` output switches it per track, so mixed 32/48 kHz packs work.
  `cen_frame` is the LVBL edge.  Output feeds the core mixer alongside the
  native chip.
* The verb → fade-port mapping (incl. the argb×4 clamp) lives in
  `cpsplus_ddr`'s verb service.
* PREFILL must stay < FIFO depth (loop-sync waits drain through the FIFO).
* If DSP pressure ever appears, the decoder's 3 multipliers can be folded
  into 1 over 3 cycles (throughput margin is ~100×).
