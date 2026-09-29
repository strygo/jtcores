# CPS-2 program capacity prototype

2026-09-27. Steve authorized the staged capacity-extension plan. This is its
first program-memory experiment, based on the integrated CPS+ core at
`8e73fb10ef1cb8a539ec94db2a0f68ef89eb689c`. It is not the complete proposed
successor or an HSFA feasibility verdict.

## Machine contract under test

The `CPS2_PRG8` compile option adds an image-selected 4 MiB plaintext ROM
window at CPU addresses `0xa00000..0xdfffff`. The original
`0x000000..0x3fffff` window, instruction decryption, RAM and device addresses
retain their existing semantics. CPU and video clocks remain unchanged.

| Region | Image payload byte offsets | SDRAM bank 0 byte offsets |
|---|---|---|
| Original program | `0..0x3fffff` | `0..0x3fffff` |
| Additional program | `0x400000..0x7fffff` | `0x800000..0xbfffff` |
| Existing VRAM/object RAM/work RAM/Z80 allocations | Existing region rules | Existing allocations between 4 and 8 MiB |

The prototype uses the existing CPS loader because this experiment stays
below its 64 MiB image limit. Header bytes 12–15 must contain `43 32 01 01`
(`C2`, version 1, program-extension capability 1), and the CPU region must
be exactly 8 MiB (`snd_start=0x2000` KiB). The remaining region starts move
by 4 MiB. Bytes 8–11 keep their existing CPS+ pack pointer/padding meaning.
Unsupported or incomplete markers leave the extension disabled. A new
download clears selection at header byte zero; a user reset retains it.
Oversized unauthorized CPU data is prevented from writing the RAM area.

This header is a **prototype**, not the final wider region-descriptor ABI.
It must use a distinct RBF/MRA identity and must never be loaded through a
production core. The program-only experiment fits the existing SDRAM bank
layout; the full enhanced-game target still requires 128 MiB.

The ROM cache includes the physical extension bit. Extension instruction
fetches use the existing completion pipeline with decryption bypassed;
original fetches keep their opcode/data distinction. Extension writes do
not select ROM. Larger graphics, sample mapping, music-control registers,
68020 and widescreen are subsequent work, not implemented by this patch.

## Patch series

| Patch | Change | Why |
|---|---|---|
| `0001-program-window.patch` | The `CPS2_PRG8` window described above | Program capacity |
| `0002-decrypt-range.patch` | `jtcps2_dec_ctrl.v` compares the 16 KiB page against `~range[9:0]` instead of `range[9:0]` | The CPS-2 key carries an encrypted address range; MAME (`cps2crypt.cpp`) decrypts opcode fetches only through page `~field` and fetches plaintext above it. The stock core compared against the raw field (`0x3c0` for vsav2/vhunt2/vsavj/sfa3, `0x200` for ssf2t), which is true for every page of the 4 MiB window, so it decrypted everything and garbled any code above the 1 MiB bound. This was the "MiSTer 1 MiB code limit". Legacy-safe: no shipped game fetches opcodes above its own bound. MAME's inclusive word convention still decrypts the single word at the bound; keep code away from it. |
| `0003-object-bank-bit.patch` | `CPS2_OBJEXT` (requires `CPS2_PRG8` and `JTFRAME_SDRAM_XL`): one extension bit per object entry, set by writes through the CPU A14 alias of the object page and cleared by the normal window, latched with the list and used as tile code bit 18; an 8 MiB high slice of tile codes at SDRAM bank 2 bytes 16–24 MiB; header capability mask `03` | The graphics half of [OBJ_BANK_BIT_PROPOSAL.md](OBJ_BANK_BIT_PROPOSAL.md) as the HBMAME `cps2evog` model validated it, sized to the 8 MiB slice VS2A needs (`backports/vamparrange/EVOLVED_CORE_PLAN.md`, "Hardware path for Phase 2 without E2"). Details below. |
| `0004-sdram-xl.patch` | `modules/jtframe/hdl/sdram/jtframe_sdram64{,_bank,_latch,_rfsh}.v`, all of it under `` `ifdef JTFRAME_SDRAM_XL ``: with `AW = 24` word address bit 23 selects one of the two 64 MiB chips of the MiSTer 128 MiB module, every command carries its chip on `SDRAM_nCS`, the open-row record and match include the chip, the programmer precharges each chip before its first activate, and every refresh slot precharges and refreshes both chips | The 128 MiB module path that 0003 named as its prerequisite (`jtframe_sdram64_bank.v` split addresses only for 32/64 MiB and the top level drove one chip select). Details in "128 MiB SDRAM controller" below; the 32/64 MiB configurations preprocess byte-identically to upstream. |

`prepare.py` applies the series in name order and verifies the cache against
the cumulative diff derived in a throwaway worktree; a cache verified against
a shorter prefix of the series advances by the patches it lacks; a patch is
immutable once a build has been recorded against it.

## Object extension slice (patch 0003)

Semantics (identical to the executable specification in
`model/gen_hbmame_model.py`, block `cps2evog`, and its validation record):

- Every object entry of each physical object RAM bank carries one extension
  bit. Any write to any word or byte of an entry through the alias window
  (CPU A14 set: `0x704000`/`0x70c000` for the two banks) stores the word and
  sets the bit; the same write through the normal window (A14 clear) stores
  the word and clears it. A13 stays a plain mirror. Whoever writes the entry
  last decides, so a recycled slot never inherits a stale bit.
- The bit is latched with the four words of the entry when the frame copy
  takes the list at the frame edge and becomes tile code bit 18:
  `code19 = {ext, y[14:13], code16}`.
- With `ext = 1` and bank bits `00` the drawer fetches the slice:
  `gfx_base + 32 MiB + code16 × 128` in image terms, SDRAM bank 2 word
  address `0x800000 + code16 × 64` (bytes 16–24 MiB of the bank). `ext = 1`
  with bank bits `01`, `10` or `11` addresses the rest of the 64 MiB library
  the successor may add; the slice core fetches nothing for it and draws it
  transparent (the drawer sees an all-ones row, exactly as an unpopulated
  ROM socket reads), so those codes never alias into the slice or the
  low library.
- Scroll layers are untouched.

Where the bit lives in this core. The proposal read `jtcps2_objram` as the
CPU's object RAM shadow. It is not: in jtcps2 the CPU's object writes go to
SDRAM (bank 0, `ORAM_OFFSET`, bank select `A15 ^ obank`, A14 dropped) and
`jtcps2_obj_frame` copies the displayed bank from SDRAM into `jtcps2_objram`
every frame, so the objram is the double-buffered frame table, filled from
SDRAM, never written by the CPU. The bit therefore needs its own on-chip
table beside the CPU write path: `jtcps1_sdram` keeps 2 × 1024 bits
(`u_objext`, one `jtframe_dual_ram`), written on every object RAM write with
`A14 & capability` at `{A15 ^ obank, A[12:3]}` and cleared during reset like
the SDRAM object table; the frame copy reads it at the entry it is copying
(`gfx_oram_ext`) and `jtcps2_objram` stores it as a fifth 1-bit lane with the
entry's words (`u_ext`, written on every entry-word write, cleared with x/y
on reset). `jtcps2_obj_scan` carries it as `st3_bank[2]`, `jtcps1_obj_draw`
as `rom_bank[2]`, and `jtcps1_sdram` turns it into address bit 23 of the
existing OBJ slot: `cps2_gfx0 = {ext, rom_bank[1], gfx0_addr}`. The two-slot
OBJ split on `rom_bank[0]` (bank 2 / bank 3) is unchanged.

Placement decision. The slice occupies **SDRAM bank 2, bytes 16–24 MiB**,
inside the OBJ slot that already serves that bank. Alternatives weighed:

| Placement | Module | Cost | Verdict |
|---|---|---|---|
| Bank 1 bytes 8–16 MiB beside an 8 MiB QSound image | 64 MiB works | Second slot on bank 1 (`jtframe_rom_2slots`, PCM keeps priority) | Rejected: Steve decided D3 = flat 24-bit QSound, so patch 0005 grows the sample library to 16 MiB in bank 1; the space is spoken for on every module size |
| Bank 0 above the program extension | 128 MiB only (64 MiB has 4 MiB spare there) | Sixth slot on the CPU bank (`jtframe_ram2_6slots`), every sprite row competing with CPU RAM/ROM, VRAM DMA, object copy and Z80 fetches | Rejected: the busiest bank, and it also needs 24-bit addressing |
| Bank 2 bytes 16–24 MiB in the existing OBJ slot | 128 MiB only | One more address bit on a slot that is alone on its bank; no new arbitration; the same address rule the 64 MiB library will use (`{ext, bank[1]}` = bits 23:22, `bank[0]` = bank 2/3) | **Adopted** |

Bandwidth: an object fetches either from the slice or from the low library,
never both, so the object stream's SDRAM load is unchanged; only its split
between banks 2 and 3 moves with the share of high-half sprites. Bank 2 has
no other requester (bank 3 also serves the scroll and star slots, bank 0 the
CPU, bank 1 the DSP samples), so the slice sits on the least loaded graphics
bank. **A 64 MiB module cannot host the slice** once the 16 MiB sample
library lands: its spare space is 4 MiB in bank 0 (bytes 12–16 MiB). It could
only with an 8 MiB sample library (bank 1 bytes 8–16 MiB, the first row of
the table), which is no longer the plan.

Module requirement and platform prerequisite. `CPS2_OBJEXT` sets
`SDRAMW = 24` in `jtcps1_sdram` (all four `ba*_addr`, `prog_addr` and the OBJ
slots), which only matches the game ports when jtframe is built with
`JTFRAME_SDRAM_XL` (128 MiB); the RTL refuses to elaborate otherwise (an
undefined macro `CPS2_OBJEXT_requires_JTFRAME_SDRAM_XL`). The pinned jtframe
distinguishes `JTFRAME_SDRAM_LARGE` (64 MiB, 23-bit, the stock CPS2 setting
in `cores/cps2/cfg/macros.def`) from `JTFRAME_SDRAM_XL` (24-bit) and rejects
both together, so the FPGA profile is `objext`:
`-d CPS2_PRG8 -d CPS2_OBJEXT -d JTFRAME_SDRAM_XL -u JTFRAME_SDRAM_LARGE`
(`build_cores.yml`). The XL path in the pinned jtframe was only partly built:
`jtframe_emu.sv` widens the ports and `jtframe_sdram64_init.v` initializes a
second chip, but `jtframe_sdram64_bank.v` split the address for `AW <= 23`
only (row `addr[AW-2:AW-1-ROW]`, column `{addr[AW-1], addr[8:0]}`, which for
`AW = 24` drops bit 9) and the top level never drove a second chip select.
Patch 0004 completes that path (next section); the game-side patch, its
download routing and the 24-bit request stream are verified here, and
`tb_obj` runs its scenes through the completed controller too (`objxl`).

Room for patch 0005 (flat 24-bit QSound). Bank 1 stays free above 8 MiB for
the 16 MiB sample library. The image then is 8 + 0.25 + 16 + 40 MiB + 8 KiB =
64.25 MiB: `JTFRAME_SDRAM_XL` already widens `ioctl_addr` to 27 bits, so the
download address is covered by the same macro this patch requires
(`jtcps1_prom_we` must take the wider bus; 0003 still slices it to 26 bits),
but the 16-bit KiB start fields overflow for the last region only: the DSP
firmware start at 64.25 MiB is `0x10100` KiB. Cheapest fix: under the
capability marker, order the regions CPU, Z80, samples, firmware, graphics
(the 8 KiB firmware before the 40 MiB graphics; graphics become the open
ended top region, `is_qsnd` bounded by `gfx_start`), so every start stays
below 64 MiB and the MRA lists `dl-1425.bin` before the graphics interleaves.
A 2 KiB unit for the start fields under the marker is the alternative. The
0003 loader keeps the stock order and checks the graphics region size
against the firmware start; 0005 revisits that check when it reorders.

Enable gating. Header bytes 12–15 are `43 32 01 <mask>`; the mask accepts
`01` (program window) and `03` (program window plus slice); any other value
leaves both off. `03` additionally requires the CPU region of exactly 8 MiB
and a graphics region of exactly 40 MiB (`qsnd_start - gfx_start ==
0xa000` KiB); a failed condition leaves both capabilities off. With the slice
capability off the bit table is written with zero, the frame lane reads
zero, `rom_bank[2]` is ignored by the SDRAM mapping, and graphics bytes above
32 MiB are dropped instead of overwriting the library. A new download clears
both capabilities at header byte zero; a user reset retains them. Without
`CPS2_OBJEXT` the RTL is textually the 0001+0002 core (widths and wires
resolve to the same constants).

Tests (`run_gate.py`, all under `tests/`):

- `lint`: the complete `jtcps2_game` elaborates with the profile and the
  MiSTer macros (nothing else compiles `jtcps2_game`/`jtcps1_video`).
- `tb_loader.sv`, `PASS loader slice`: marker `03` enables both capabilities,
  2,565 graphics byte mappings over a 40 MiB region (the last 8 MiB at bank 2
  word `0x800000+`, the first 32 MiB as stock, the firmware following at
  40 MiB, the sample region unmoved); `01` with a 40 MiB region enables the
  program window only and drops the slice bytes; `03` with 32 or 48 MiB of
  graphics or a 4 MiB CPU region fails closed; every single-bit mutation of
  `43320103` leaves the slice off (only the mutation that yields `01` keeps
  the program window); `02` is rejected; a new download clears both.
- `tb_obj.sv`: the real download router, `jtcps1_sdram` (object write slot,
  bit table, frame-copy slot, OBJ slots), `jtcps2_obj` (frame copy,
  `jtcps2_objram`, scanner, drawer, line buffer) with a four-bank 24-bit SDRAM
  model; entries are written through the CPU port as `jtcps2_main` presents
  them and every tile fetch is checked at the SDRAM against the set the list
  must produce. Scenes: both windows, alias-then-normal rewrite clears, a
  byte write through the alias sets, a 2×2 block with both flips from the
  slice, a 1×3 block from bank 3, `ext` with bank bits `01` (nothing fetched,
  later entries still drawn), the A13 mirror, one frame mixing both halves;
  the second physical bank through the swap; recycled slots after the swap;
  swapping back with bank 0's bits retained; and the legacy profile (a new
  download with `01`, the same alias writes render as plain mirrors, zero
  slice fetches). Bank 1 must never be read.
- Mutation: `+MUTATE` forces the objram lane's write enable off; the same
  test must fail (`run_gate.py` requires it and records the failing
  assertion).
- `tb_program.sv` runs unchanged with 24-bit addresses, plus `+HOLD_ADDR`
  for the slice hook (below).

Diagnostic image (`build_controls.py --machine vsav2`, control `slice`,
RBF `jtcps2-prg8-objext`): capability `03`; the graphics region grows to
40 MiB with an 8 MiB generated member after the eight stock members, in raw
ROM order, in which unshuffled tile code `c` is a solid block of pen
`c mod 15` (the loader's bit-3-to-bit-20 scramble is MAME's per-2 MiB tile
unshuffle, verified against `extraction/cps2gfx.py`); no game art. Its reset
hook (`diagnostics/slice_hook.s`, four encrypted vector bytes changed as for
`hook`) runs the extension boundary checks, writes a 16-colour palette,
draws four rows of eight objects with priority 7, holds them for about
3.5 seconds, restores the registers and jumps to the game's entry. **What a
human should see** on the objext core at power-on, before Vampire Savior 2
boots (black background, rows 16 pixels tall from near the top left):

1. `y=0x30`: eight objects written through the normal window with tile codes
   `0x0100`–`0x0107` of the game's own library — whatever stock art lives
   there, possibly blank.
2. `y=0x50`: the same codes written through the A14 alias — seven solid
   colour blocks, blue, green, red, cyan, magenta, yellow, white (pens 1–7 of
   the hook's palette: `0x100 mod 15 = 1`), then a 2×2 block (codes
   `0x0200/0x0201` over `0x0210/0x0211`): green and red above red and cyan.
3. `y=0x70`: alias entries with y bank bits `01` — nothing at all.
4. `y=0x90`: alias entries whose x word was then rewritten through the normal
   window — stock art again, identical to row 1.

Then the game starts normally and must play exactly as `hook` does (its
object list never drives A14, so the slice core renders it from the low
library: the adoption proof). On the `program` RBF the `slice` MRA must not
boot (marker `03` is rejected there, so the reset vector points at an empty
window); on the stock core it must not load at all. The RTL hook run
executes the same program with the hold count at `0xa00100` overridden to 2
(`+HOLD_ADDR`), the only difference from the shipped bytes; it confirms the
palette, object and register writes reach their targets and the game entry
is reached, not what the picture looks like.

## 128 MiB SDRAM controller (patch 0004)

What the module is (sources: MiSTer-devel/Hardware_MiSTer
`releases/sdram_xsds_2.9.pdf` (4.21.2021) and `sdram_xsds_3.0.pdf`
(3-04-2023), "SDRAM board (dual-chip) for MiSTer (extra slim)", drawn by
Sorgelig; the Alliance Memory AS4C32M16SB datasheet Rev 1.4, June 2024;
misterfpga.org topic 3440, robinsonb5 2021-10-11: "a single select is
inverted for one of the two chips"; topic 2480 is the v2.9 board thread and
adds build detail only):

- Two AS4C32M16SB-6TIN (U1, U2): 8M words × 16 × 4 banks each, row A0–A12,
  column A0–A9, A10 = auto/all-bank precharge, 8192 refresh cycles per 64 ms
  (tREFI 7.8 µs), -6 grade tRC 60, tRFC 60, tRCD 18, tRP 18, tRRD 12, tMRD 12,
  tRAS 42–120 000, tWR 12 ns, tCK 10 ns at CL 2. Power-up: precharge all,
  mode register set, at least two auto-refresh cycles (either order).
- Every pin is shared between the chips: A0–A12, BA0–1, DQ0–15, CLK, RAS#,
  CAS#, WE#; DQML is tied to A11 and DQMH to A12 on both chips (the
  "shorted pins" jtframe's `MISTER=1` A[12:11]/DQM handling exists for);
  CKE is tied to VCC (no power-down or self-refresh entry).
- The header's single `SDRAM_nCS` drives U1's CS# directly and U2's CS#
  through U3, an LVC1G04 inverter. **nCS low addresses U1 (chip 0, word
  address bit 23 = 0); nCS high addresses U2 (chip 1, bit 23 = 1).** Exactly
  one chip decodes every clock; there is no "no chip selected" state. NOP is
  RAS/CAS/WE high at either level. The classic "command inhibit" (CS high
  with RAS/CAS/WE low) is LOAD MODE on U2, so the controller must never
  emit it; jtframe never did (its NOP is `0111`) and 0004 asserts it in
  simulation.
- A 64 MiB core (nCS always low) never initializes, refreshes or reads U2:
  U2 stays deselected and its DQ drivers off. `tb_sdram` confirms it against
  the stock controller (chip 1 decoded 0 commands).

RTL (every line under `` `ifdef JTFRAME_SDRAM_XL ``; `run_gate.py`'s
`sdram text` gate proves the four files preprocess byte-identically to the
pinned upstream without the macro, so 32/64 MiB builds are untouched; the
burst controller, which instantiates the same bank/refresh modules with its
own alternating-chip `XL` semantics, keeps them):

- `jtframe_sdram64_bank.v`: `XL = AW==24`; row `addr[21:9]` and column
  `{addr[22], addr[8:0]}` exactly as `AW = 23`; `chip = addr[23]` is a new
  output valid with `cmd`, so every ACTIVATE, READ, WRITE and PRECHARGE the
  bank issues names its chip; the open-row record `row` becomes
  `{chip, row}`. For a `PRECHARGE_ALL` bank (the programmer) the "all banks
  precharged" flag is kept per chip: its precharge-all only reaches the chip
  it addresses, so the first write to the other chip precharges that chip
  too before activating (a re-download into a running core can find rows
  open in both chips).
- `jtframe_sdram64_latch.v`: the match key is `{addr[23], addr[21:9]}`
  against the 14-bit row, so bank N of chip 0 and bank N of chip 1 never
  count as the same open row.
- `jtframe_sdram64_rfsh.v`: new parameter `BOTH`. A refresh slot is
  PRECHARGE ALL chip 0, PRECHARGE ALL chip 1, REFRESH chip 0, REFRESH chip 1,
  then the tRFC wait: 11 clocks instead of 10 at 96 MHz (8 instead of 6 at
  48 MHz), chained slots 9 instead of 8. `RFSHCNT` keeps its per-chip
  meaning (9 per 64 µs line = 9000 per 64 ms per chip against the 8192
  required), both chips are precharged before the banks' bookkeeping
  assumes it, and each chip sees the 64 MiB module's refresh timing. Cost:
  one clock per slot, 9 clocks per 6144-clock line (+0.15 % of the bus, from
  1.5 % to 1.6 % refresh overhead). The alternative, doubling `RFSHCNT` and
  alternating chips (what the burst controller does), would cost 72–90
  clocks per line and still needs the both-chip precharge.
- `jtframe_sdram64.v`: each command source (four banks, programmer, init,
  refresh) exports its chip; `next_chip` is muxed exactly like `next_cmd` and
  the pair is registered together, `sdram_ncs = ncs_r`, `ncs_r <=
  next_cmd[3] ^ next_chip` (`cmd[3]` is 0 for every command jtframe issues,
  so the pin is the chip bit and NOP cycles keep the last chip selected,
  which is a NOP for it and a deselect for the other). `u_init` gets
  `.XL(AW==24)` (its existing second-chip sequence is now driven: chip 0 and
  chip 1 each get precharge all, two refreshes and load mode) and `u_rfsh`
  gets `.BOTH(AW==24)`.
- Unchanged: `jtframe_sdram64_init.v`, the DQ/DQM/A[12:11] handling, the
  bank arbitration, `jtframe_dwnld` (which already puts its bank[2] = chip
  into `prog_addr[23]`), all game-side files.

Tests (`run_gate.py`, `tests/sdram_chip.sv`, `tests/tb_sdram.sv`,
`tests/tb_obj.sv` with `REAL_SDRAM`):

- `sdram_chip.sv`: one AS4C32M16SB-class chip at command level for Verilator
  (per-byte drive enables instead of a tristate bus), enforcing activate on
  an open bank, read/write on a closed bank, refresh or load mode with an
  open bank, the JEDEC power-up order before the first activate, tRCD, tRP,
  tRAS min/max, tRC, tRRD, tRFC (66 ns, the Micron value jtframe's own tests
  use), tWR and tMRD, CL 2/3, BL 1–8 sequential bursts, write DQM, the
  two-clock read DQM latency and auto precharge. Unwritten words read back a
  pattern of `(chip, bank, row, column)`, so a misplaced address bit is
  visible as wrong data anywhere.
- `tb_sdram.sv`: `jtframe_sdram64` in the CPS2 profile (64-bit bursts on
  banks 0/2/3, 32 on bank 1, only bank 0 writable and auto-precharged, one
  refresh trigger per 64 µs) driving two chip models wired as the module
  (`cs_n(sdram_ncs)` and `cs_n(~sdram_ncs)`), with a bus resolver that fails
  on two chips driving at once or a chip driving during the controller's
  write cycle. Sequence: init (both chips precharged, refreshed twice and
  mode-set CL 2/BL 4 before any activate), programmer writes in every bank
  across the 64 MiB boundary (words `0x7ffffc`–`0x800003`, the same row and
  column in both chips with different data, random words with byte masks),
  read-back through the bank requesters against a shadow, alternating chips
  back to back in the same bank and row on banks 1–3 (row open in chip 0,
  chip 1, back to chip 0, a row hit inside chip 1, a different row), bank 0
  writes and reads alternating chips, a programmer restart with rows open
  in both chips in both orders, and 64 ms of random traffic on four banks
  under refresh with every beat checked (per-chip refresh count in the
  window ≥ 8192 and equal for both chips, no row older than 120 µs). The
  same testbench compiled without the macro (`sdram64`, `AW = 23`) runs the
  stock upstream controller against the same model and address contract,
  which validates the model and requires chip 1 to decode nothing.
- Mutation: `+MUTATE` forces the controller's open-row match to the 64 MiB
  compare (row bits only, chip ignored); the test must fail (it reads
  another row's data from chip 1 without an activate).
- `objxl`: `tb_obj` with `-DREAL_SDRAM` replaces its behavioural SDRAM with
  the controller at `AW = 24` and the two chips: the five object scenes run
  through the real controller, every bank 2/3 read beat is checked against
  the chip pattern of the requested word (the 24-bit request stream reaches
  the right chip, row and column), the slice must come from chip 1 bank 2,
  chip 1 must never be written and the object table stays in chip 0 bank 0.

Not verifiable here, only on the module: signal integrity with two loads
on every shared line at 96 MHz and the inverter's delay on U2's CS# against
the command setup window (the SDC constrains `SDRAM_nCS` like the other
command pins; U2 sees it later by the LVC1G04 propagation delay); read data
timing from U2 with the shifted SDRAM clock; the objext Quartus build's
timing closure; data retention with real leakage. The one-clock LOAD MODE
with A = 0 that the FPGA's cleared command register shows at power-up
(pre-existing, both modules) is overridden by the init sequence. An XL core
on a 64 MiB module reads a floating bus for every chip-1 address; the
loader cannot detect the module, so the slice controls must only be run on
the 128 MiB module.

## Rebuilding and acceptance

From the Capcom repository root:

```
python3 cpsplus/evolution/run_gate.py
python3 cpsplus/evolution/run_gate.py --work cpsplus/evolution/work/clean
python3 cpsplus/evolution/run_gate.py --with-game-hook                  # sfa3 controls
python3 cpsplus/evolution/run_gate.py --with-game-hook --machine vsav2  # vsav2 controls
```

The command fetches the pinned core and its required submodules, verifies
the source and tracked patch series, builds the pinned vasm assembler using
the committed Gold toolchain recipe in a separate cache, lints the complete
game module, and builds/runs the Verilator tests (loader, CPU, object
extension and its mutation, the 128 MiB SDRAM controller: upstream text
identity without the macro, lint at `AW` 24/23/22, `tb_sdram` on the stock
64 MiB controller and on the XL controller, the XL match mutation, and
`tb_obj` through the real controller). Every mutation must fail. It requires
Python 3, Git, a C++ compiler, make and Verilator; game controls also use Go
to rebuild the pinned upstream image assembler. The default output directory
is disposable; nothing in it is a source input. Existing source caches with
unknown edits are rejected.

Controls exist for two machines (`build_controls.py --machine`): `sfa3`
(baseline, legacy, enabled, hook) and `vsav2` (the same four plus `hook2`
and `slice`).
`hook2` patches the reset vector to `0x3fb100`, inside the original window
in an all-FF stock cave above the 1 MiB key bound, where 12 bytes of
plaintext code leave a witness in D7 and jump to a second entry of the
extension hook that checks it. The Verilator hook test counts fetches from
that cave (`+INWINDOW`). On hardware it is **not** a usable negative control:
on 2026-09-29 it booted on the patch-0001 core as well, because vsav2's fault
vectors (bus, address, illegal, privilege, line A/F) all enter one handler at
`0x150` that restarts the game, so garbled code at boot yields a normal-looking
boot. `hook3` is the same in-window code preceded by a ~3.5 s spin on a hold
count stored at `0xa00180` in the extension (the RTL run overrides it to 2
via `+HOLD_ADDR`): a core that executes plaintext above the bound pauses
visibly before booting, a core that garbles it boots at once. The RTL-side
differential is on record: the 0002-era `tb_program.sv` run against patch
0001 alone fails at its first page above zero (`opcode/data selection failed
at 00004000 fc=6`), the raw-field comparison the patch removes.

The optional game-hook gate discovers canonical `sfa3.zip` and `qsound.zip`
through the repository ROM paths, `CAPCOM_ARCADE_ROM_PATH`, or `--rompath`.
It verifies the pinned stock MRA and every input member CRC, produces four
isolated MRAs (baseline, legacy mode, enhanced mode with unchanged program,
and reset hook), and checks the hook using the real CPU/decrypt RTL. Only four
encrypted reset-vector bytes change; all other original program bytes and
assets remain byte-identical. The 70-byte plaintext hook checks extension
boundaries, preserves registers/SR/stack, and jumps to the original reset
entry. A failed check stops there. Reaching that entry does not establish
that the complete game boots or that its internal ROM tests accept the patch.
No source ROM archives are modified or included in the public core branch.
The builder also assembles all four MRAs with the pinned upstream `jtframe`
tool and compares their actual images: legacy equals baseline, extension
placement matches the runtime fixture, and graphics, audio, firmware, key and
video configuration remain byte-identical.

The original diagnostic assembly contains no game assets. The CPU test
uses the actual fx68k, CPS2 main/decrypt logic and shared SDRAM slots/cache;
only the external SDRAM responses are modeled. It exercises calls in both
directions, the `0xbffffe/0xc00000` split, the last extension word, alternating
cache addresses, an interrupt handler in extension ROM, RTE and user reset.
Loader tests check both byte lanes, malformed capabilities and region
boundaries. Decode tests check legacy and enhanced selection and opcode/data
views. This does not model the electrical SDRAM interface or prove full-game
compatibility.

`export_core.py` creates a separate source checkout for review and CI. Its
workflow builds the exact baseline and program prototype independently using
a pinned Quartus container. Reports are collected even on failure. An RBF is
not accepted merely because Quartus emitted it: timing must pass, then the
core needs real MiSTer tests. The exported source contains no game ROMs.

`collect_build.py RUN_ID` verifies a run's source files against the local
patch, requires successful compile/timing and artifact-upload steps, checks
fitter status, timing and artifact hashes, and builds an installable test kit
using the declared ROM inputs. It can recover an isolated failure in the
post-build binary-naming step by naming the verified original RBF locally;
other failed steps reject the run. It never installs the kit. The hardware
procedure is [HARDWARE.md](HARDWARE.md).

## Verified result — 2026-09-27

The RTL and SFA3 image/hook gates passed from fresh empty scratch space.
Both full-core Quartus builds passed on their first fitter seed:

| Measurement | Pinned CPS+ baseline | 8 MiB program prototype |
|---|---:|---:|
| ALMs | 19,640 (47%) | 19,544 (47%) |
| Registers | 31,227 | 31,218 |
| RAM blocks | 235 | 235 |
| DSP blocks | 46 | 46 |
| Worst setup slack | +0.044 ns | +0.282 ns |
| Worst hold slack | +0.225 ns | +0.113 ns |

The small utilization difference is a synthesis/placement result, not a
claim that additional capacity intrinsically saves logic. All five reported
timing categories passed. These results establish a fitting FPGA build;
they do not substitute for SDRAM and full-game tests on a real MiSTer.
The collector also confirms that the system and SDRAM constraint files
loaded and that constraint coverage matches the baseline. Both builds retain
the upstream unconstrained SDRAM data inputs and joystick clock, plus the
same two critical-warning messages. Therefore “timing passed” refers to the
paths covered by those constraints, not a complete board-interface timing
proof. The detailed coverage and warnings are preserved in the build record.

(That first build's record is now `quartus_build_36351443421.json`; `quartus_build.json` holds the latest build.)
[Build 36351443421](https://github.com/strygo/jtcores/actions/runs/36351443421)
has an overall failure status because both post-build naming steps could
not write into the container-owned output directory. Compilation, timing
and artifact upload succeeded. The collector verified and recovered the
original binaries; the workflow's copy permissions are corrected for future
builds. No RTL change or repeat synthesis was required for recovery.

Recreate the kit while the build artifacts are available:

```
python3 cpsplus/evolution/collect_build.py 36351443421
```

[validation.json](validation.json) records the software gates;
[quartus_build.json](quartus_build.json) records the exact built revisions,
reports, RBF digests and kit digest. GitHub artifacts expire after 30 days;
`export_core.py` plus the pinned workflow regenerates a build afterward.
The source branch is `codex/cps2-program-capacity` in `strygo/jtcores`.
Its later documentation/test/workflow updates do not change the built RTL.

On 2026-09-27 Steve reported that all four supplied controls seemed fine and
that he played through the title screens into a fight. This records an initial
real-MiSTer smoke pass for baseline, legacy, enabled and hook. Normal startup
in the supplied hook implies its extension call/return and boundary checks
completed before SFA3 began. Steve then reported that OSD reset worked for all
four controls, all service-menu memory checks were OK, and the requested game
switching seemed to work. The requested basic hardware checks therefore pass
by user report. OSD reset exercises the game within the loaded FPGA core;
the hook starting again supports retained extension selection after reset.

Normal MRA selection reloads the FPGA bitstream, even for MRAs sharing an RBF:
MiSTer's [xml_load](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/support/arcade/mra_loader.cpp)
calls [fpga_load_rbf](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/fpga_io.cpp),
which resets and reconfigures the FPGA. The switching result is therefore a
reload/launch check; it does not validate clearing the extension marker on a
new download into a retained FPGA configuration. That behavior has RTL test
coverage, but no dedicated hardware observation. The stock service check also
does not establish exhaustive coverage of the added program window.

Hardware details, explicit audio confirmation and sustained compatibility
are not yet recorded. Exact reports, the supplied-kit identity and remaining
checks are in the `hardware_smoke` entry of [validation.json](validation.json);
complete hardware acceptance remains open.

## 2026-09-28: patch 0002 and the vsav2 controls

From the existing verified cache (`run_gate.py --with-game-hook --machine
vsav2`): loader, CPU runs 1/2, decode (262,272 cases), **key range (16,448
cases: field `0x3c0` decrypts pages 0–0x3f only, field `0x200` the whole
window, data and extension fetches untouched)**, write rejection, upstream
MRA assembly of the five vsav2 controls (baseline/legacy 46,407,744 B,
enabled/hook/hook2 50,602,048 B), the vsav2 `hook` (4 program bytes changed)
and `hook2` (16 bytes: vector + 12 code bytes at `0x3fb100`) RTL hook
tests, and the sfa3 `hook` with the two-entry extension code (590 B). The
The five vsav2 controls also boot as complete games in the HBMAME `cps2evo`
model (`model/run_controls.py`, `model/controls_validation.json`): enabled,
hook and hook2 are pixel-identical to stock at five capture frames, with RAM
differing only on the reset stack at the first two. The FPGA build for this
series is `strygo/jtcores` [run 36515396738](https://github.com/strygo/jtcores/actions/runs/36515396738)
(commit `5ed6101`): both profiles compiled and passed the constrained-path
timing checks on the first seed (program profile 19,599 ALMs, minimum
reported slack +0.086 ns; constraint coverage identical to the baseline).
`collect_build.py 36515396738` verified it and built the kit
(`quartus_build.json`). Until Steve runs the controls, the key-range fix is
RTL-, emulation- and fit-verified, not hardware-verified.

## 2026-09-29: patch 0003, object extension slice

From the existing verified cache, which `prepare.py` advanced from the
0001+0002 prefix (`run_gate.py --with-game-hook --machine vsav2`, then
`--with-game-hook` for sfa3): game lint (0 errors), loader (65,540 CPU
mappings) and **loader slice (2,565 graphics mappings)**, CPU runs 1/2,
decode (262,272 cases), key range (16,448 cases), write rejection, **object
extension (five scenes: 192, 32, 32, 192 and 208 tile fetches matching the
expected sets, 96/16/16/96/0 of them from the slice, opaque pixels in every
scene)**, **mutation (lane write enable forced off: `tb_obj` fails at frame 19
with the slice object's code `0x2345` fetched from the low library)**, upstream
MRA assembly of the six vsav2 controls (baseline/legacy 46,407,744 B,
enabled/hook/hook2 50,602,048 B byte-identical to the 2026-09-28 record,
**slice 58,990,656 B**: 56.25 MiB of regions plus firmware and header), and the
vsav2 `hook`, `hook2` and `slice` RTL hook tests (the slice hook is 462 bytes,
4 program bytes changed, hold count overridden to 2). The slice control's
pattern member is 8,388,608 B (`83d83ed5…`), its MRA `2ccc8f0d…`, RBF
`jtcps2-prg8-objext`. No FPGA build of the `objext` profile exists yet; the
128 MiB SDRAM path in jtframe is the prerequisite named above. Nothing about
patch 0003 is hardware-verified.

## 2026-09-29: patch 0004, 128 MiB SDRAM controller

From the existing verified cache, which `prepare.py` advanced by 0004
(`run_gate.py --with-game-hook --machine vsav2`, exit 0): the previous gates
unchanged (game lint, loader 65,540 + slice 2,565 mappings, CPU runs 1/2,
decode, key range, write rejection, the five object scenes and the lane
mutation), then **sdram text** (four files byte-identical to upstream
without the macro), **sdram lint** (AW 24 with the macro, 23 and 22
without, 0 errors), **sdram64** (stock 64 MiB controller on the two-chip
model: chip 0 initialized with 2 refreshes, chip 1 behind the inverted CS
decoded 0 commands, 301 programmer words and 600 bursts, 907/0 activates,
8,995 refreshes in a 64 ms window under 863,999 reads and 83,000 writes,
2,880,477 beats verified), **sdram** (XL controller: both chips precharged,
refreshed twice and mode-set CL 2/BL 4 before the first activate; 643 words
across the 64 MiB boundary in every bank; alternation 768/707 activates on
chip 0/1; programmer restart precharging each chip in both orders;
8,991/8,991 refreshes per chip in 64 ms under 862,088 reads and 83,421
writes, 2,873,862 beats verified, no row older than 120 µs, no timing rule
violated), **mutation** (open-row match without the chip bit: `tb_sdram`
fails at 181 µs reading `e8eb` for `d9bd`, another row of chip 1 without an
activate), **objxl** (the five scenes through the real controller: 3,968
beats checked against the chip pattern, 1,408 from the slice in chip 1
bank 2, 832 from bank 3, chip 1 read 352 bursts and was never written,
55,436 refreshes per chip), and the vsav2 controls (upstream MRA assembly,
`hook`, `hook2`, `hook3`, `slice` RTL hooks) as before. The controller
runs at 100 MHz in the testbenches, the faster of the two periods jtframe's
own `sdram_bank64` tests use. No FPGA build of the `objext` profile has
been dispatched; the profile lints with 0004 applied and `collect_build.py`
already verifies the jtframe files through `patched_files()`.

## Remaining acceptance

- Dispatch the `objext` Quartus build with 0004 (`export_core.py`, then the
  workflow), collect it, and run the vsav2 `slice` and `hook` controls on
  the 128 MiB module (HARDWARE.md): the two-chip timing, the inverter delay
  on U2's CS# and U2's refresh are hardware-only checks.

- Record the tested SDRAM module/capacity and MiSTer version.
- Explicit native-audio confirmation for the stock controls and extension hook.
- Sustained gameplay and broader hardware/compatibility coverage beyond the
  reported startup, reset, service-check and MRA-reload passes.
- If retained-core re-download behavior is required on hardware, use a
  dedicated test that does not reconfigure the FPGA between images.
- Complete HSFA code/data, RAM and asset budgets before substantial graphics
  and sample expansion work; those proposed capacities remain provisional.

The generic platform tests do not establish that the full HSFA port fits or
meets the original CPU and rendering limits.
