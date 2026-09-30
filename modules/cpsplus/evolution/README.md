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
| `0005-sdram-ncs-constraint.patch` | `modules/jtframe/target/mister/syn/sdram_clk96.sdc`, 15 appended lines: `SDRAM_nCS` gets a `set_output_delay` pair against the `SDRAM_CLK` generated clock with the AS4C32M16SB input setup and hold times (max 1.5 ns, min -0.8 ns); no logic changes | Since 0004 the pin toggles per command, and the `objext` build of run 36621029996 reported it as a new unconstrained output (the only coverage difference from the baseline). The constraint puts the path under analysis, restores coverage parity, and makes the reported setup slack the U2 inverter budget. Details in "Chip-select timing constraint" below. |
| `0006-qsound-flat.patch` | `CPS2_QSND24` (requires `CPS2_OBJEXT`, same `objext` CI profile): the DSP sample address latch keeps all eight bank bits (`qsnd_addr` 23 to 24 bits, `PCM_AW` 24, the PCM slot address `{bit 23 & capability, bits 22:0}`), a 16 MiB sample library in SDRAM bank 1 bytes 0..16 MiB, the loader takes the 27-bit download bus and, under header capability bit `04`, the flat region order CPU, Z80, samples (exactly 16 MiB), DSP firmware (exactly 8 KiB), graphics (open-ended); accepted masks `01`, `03`, `05`, `07` | Steve's decision D3 (2026-09-29, flat 24-bit): appended sample rows with bank byte >= `0x80` are what the stock vsav2 Z80 driver already sends (`vs2.01` `0x1428-0x1444`, `0x8000\|bank`, never masked) and what MAME's LLE fetches (`model/qsound_flat_experiment.json`); the stock 8 MiB region merely mirrors. With the capability off the core mirrors as stock. Details in "Flat 24-bit QSound" below. |

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
| Bank 1 bytes 8–16 MiB beside an 8 MiB QSound image | 64 MiB works | Second slot on bank 1 (`jtframe_rom_2slots`, PCM keeps priority) | Rejected: Steve decided D3 = flat 24-bit QSound, so patch 0006 grows the sample library to 16 MiB in bank 1; the space is spoken for on every module size |
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

Room for patch 0006 (flat 24-bit QSound; 0005 is the chip-select constraint). Bank 1 stays free above 8 MiB for
the 16 MiB sample library. The image then is 8 + 0.25 + 16 + 40 MiB + 8 KiB =
64.25 MiB: `JTFRAME_SDRAM_XL` already widens `ioctl_addr` to 27 bits, so the
download address is covered by the same macro this patch requires
(`jtcps1_prom_we` must take the wider bus; 0003 still slices it to 26 bits),
but the 16-bit KiB start fields overflow for the last region only: the DSP
firmware start at 64.25 MiB is `0x10100` KiB. Patch 0006 took the cheapest
fix, the region reorder under the capability marker (see "Flat 24-bit QSound"
for the evidence against the 2 KiB-unit alternative); the 0003 loader keeps
the stock order and its graphics size check for marker `03`.

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
`hook`) runs the extension boundary checks, writes a 16-color palette,
draws four rows of eight objects with priority 7, holds them for about
3.5 seconds, restores the registers and jumps to the game's entry. **What a
human should see** on the objext core at power-on, before Vampire Savior 2
boots (black background, rows 16 pixels tall from near the top left):

1. `y=0x30`: eight objects written through the normal window with tile codes
   `0x0100`–`0x0107` of the game's own library — whatever stock art lives
   there, possibly blank.
2. `y=0x50`: the same codes written through the A14 alias — seven solid
   color blocks, blue, green, red, cyan, magenta, yellow, white (pens 1–7 of
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
the command setup window (upstream's SDC constrains none of the command
pins; run 36621029996 reported `SDRAM_nCS` as a new unconstrained output
once it toggled, and patch 0005 constrains it; U2 sees it later by the
LVC1G04 propagation delay); read data
timing from U2 with the shifted SDRAM clock; the objext Quartus build's
timing closure; data retention with real leakage. The one-clock LOAD MODE
with A = 0 that the FPGA's cleared command register shows at power-up
(pre-existing, both modules) is overridden by the init sequence. An XL core
on a 64 MiB module reads a floating bus for every chip-1 address; the
loader cannot detect the module, so the slice controls must only be run on
the 128 MiB module.

## Chip-select timing constraint (patch 0005)

What the fitter sees (MEASURED in the run 36621029996 `objext` reports): the
controller launches every command pin from the 96 MHz PLL output 4
(`clk96`, 0 ps) into an IO output register (`sys.tcl` sets
`FAST_OUTPUT_REGISTER ON -to SDRAM_*`; the fit report lists `SDRAM_nCS`,
`SDRAM_nRAS`, `SDRAM_nWE` and `SDRAM_A[*]` alike with "Output Register: yes",
3.3-V LVTTL, 16 mA, slew rate 1). The pin clock is PLL output 5 (`clk96sh`,
−5034 ps, so the SDRAM samples 5.383 ns after the launch edge); jtframe's
`sdram_clk96.sdc` declares it as `SDRAM_CLK`, a 180° generated clock
(5.208 ns, 0.175 ns pessimistic). Upstream constrains no SDRAM output: every
command pin is an "unconstrained output" in the baseline, and `SDRAM_nCS` was
absent from that list only because a 64 MiB core holds it at a constant.
Once 0004 toggled it, the collector's coverage comparison flagged exactly that
one port (+1 port, +1 path, nothing else); the kit was packaged with the review
recorded (`collect_build.py --accept-coverage-change`, see `coverage_review`
in the build record).

The patch appends two lines to that SDC:

```
set_output_delay -clock [get_clocks {SDRAM_CLK}] -max  1.5 [get_ports {SDRAM_nCS}]
set_output_delay -clock [get_clocks {SDRAM_CLK}] -min -0.8 [get_ports {SDRAM_nCS}]
```

The figures are the AS4C32M16SB input setup and hold times (datasheet Rev 1.4,
June 2024, table "AC Characteristics": `tIS` 1.5 ns, `tIH` 0.8 ns for the -6
and -7 grades). The setup requirement is therefore `tco + 1.5 ≤ 5.208 ns` at
the pin, and the slack Quartus reports on this path is the whole budget for the
module's U3 inverter in front of U2's CS# (SN74LVC1G04, SCES214AF: 0.7–3.3 ns
at 15 pF, 1.0–4.2 ns at 30–50 pF, 3.3 V ± 0.3 V); the inverter only adds to
U2's hold margin. Because `SDRAM_nCS` shares the launch path of every other
command pin, its slack also stands for theirs. The other pins stay as upstream
leaves them: constraining them too would be an improvement, but it would make
the profile's coverage differ from the baseline again, and that is a separate
decision. On a 64 MiB build the pin is constant and the two lines constrain no
path, so the `program` profile is unaffected.

What the next build answers: `collect_build.py` records the `SDRAM_CLK`
setup row of the STA summary per profile as `sdram_ncs_output_setup_slack_ns`
(the only path latched by that clock). A nonnegative value is the inverter
budget in ns; a negative value fails the build's timing, the collector refuses
the kit, and the finding goes to Steve as-is rather than being relaxed. The
gate `sdc` (`run_gate.py`) checks the text locally, since Quartus only runs in
CI: the pair exists, names a clock the file creates and a port `sys_top.v`
declares, carries the datasheet figures, and four mutations (undeclared port,
uncreated clock, another figure, missing hold line) are each rejected.

## Flat 24-bit QSound (patch 0006)

Decision D3 (Steve, 2026-09-29, flat 24-bit). The facts it rests on: the stock
vsav2 Z80 driver sends every descriptor row's bank byte unmasked
(`vs2.01` `0x1428-0x1444`: register `((ch-1)<<3)&0x78 <- 0x8000|bank`; the
only `0x7f` mask in the driver is on the row index), MAME's device is a 24-bit
ROM space in which an 8 MiB region merely mirrors, and MAME's LLE, the real
dl-1425 program on the DSP16A core, fetched a 1 kHz tone from bank `0x80` and
a looped tone from bank `0xff` offset `0xff00` through that stock driver
(MEASURED, `model/qsound_flat_experiment.json`). A sample library therefore
grows by appending rows with bank bytes `0x80..0xff`; nothing maps.

RTL (every line under `` `ifdef CPS2_QSND24 ``; the macro requires
`CPS2_OBJEXT`, hence `CPS2_PRG8` and `JTFRAME_SDRAM_XL`, because
`jtframe_romrq` pads a slot address to `SDRAMW` bits, so a 24-bit `PCM_AW`
needs `SDRAMW = 24`, and because a 64.25 MiB image needs the 27-bit download
bus; it joins the `objext` CI profile rather than adding a fourth Quartus job):

- `jtcps15_sound.v`: `qsnd_addr` is 24 bits and the bank latch takes
  `dsp_ab[7:0]` instead of `[6:0]`. The DSP's external address bits 14:0 are
  the bank (`dsp_io_map` in MAME, `0x0000-0x7fff mirror 0x8000`); the 24-bit
  space keeps eight of them.
- `jtcps1_sdram.v`: `PCM_AW = 24`; the PCM slot address is
  `{qsnd_addr[23] & cps2_qsnd_ext, qsnd_addr[22:0]}`, so with the capability
  off bit 23 is cleared, which is the stock 8 MiB mirror (bank `0x80` plays
  bank `0x00`). The library sits in **SDRAM bank 1 bytes 0..16 MiB**, word
  addresses `0..0x7fffff`, chip 0 of the 128 MiB module (on which bank 1 is
  32 MiB; the slice never touches bank 1, `tb_obj` asserts it).
- `jtcps2_game.v`: the 24-bit wire, and `jtcps1_sdram` gets all 27 bits of
  `ioctl_addr` (0003 sliced it to 26).
- `jtcps1_prom_we.v`: the 27-bit download bus; under the macro every region
  compare uses all 17 KiB bits (`bulk_addr[26:10]`), so an address above 64 MiB
  never aliases a low region; a new output `cps2_qsnd_ext`; header byte 15
  becomes a three-bit capability mask.

Header contract. `43 32 01 <mask>`, `mask` bit 0 = program window (0001),
bit 1 = object slice (0003), bit 2 = flat QSound (0006); accepted masks are
`01`, `03`, `05` and `07`, anything else leaves every capability off. Every
mask needs the 8 MiB CPU region; `03` keeps 0003's rule (stock order, graphics
exactly 40 MiB); `05` and `07` need the **flat order**: CPU, Z80, samples of
exactly 16 MiB, DSP firmware of exactly 8 KiB on an 8 KiB boundary, then
graphics as the open-ended top region (`qsnd_start - pcm_start == 0x4000`,
`gfx_start - qsnd_start == 8`, `qsnd_start[2:0] == 0`). The four 16-bit KiB
start fields keep their meaning (Z80, samples, graphics, firmware) and stay
below 64 MiB while the download itself reaches 64.25 MiB + 8 KiB + 64 B with
the slice (67,379,264 B for vsav2). Graphics bytes past the library (32 MiB,
40 MiB with the slice) are dropped, never wrapped; the 07 slice size is
therefore bounded at download instead of checked in the header (the header
has no field left for the size of an open-ended region). A new download
clears all three capabilities at byte zero; a user reset retains them. Without
the capability the regions, the mirror and everything else are stock, and the
stock loader already writes a 16 MiB sample region to bank 1 (`pcm_addr[23:1]`
covers it), so a mask-`01` image with the 16 MiB library loads on any core of
the series and simply mirrors.

Why the reorder and not a 2 KiB unit for the start fields (both fit the
16-bit fields up to 128 MiB, both are expressible in the upstream MRA
generator: `order=[...]` versus `offset={bits=11}` in `cores/cps2/cfg/mame2mra.toml`):

| Evidence | Reorder (adopted) | 2 KiB unit |
|---|---|---|
| Open-ended top region | Graphics, whose overflow the loader drops | DSP firmware, whose bytes address the DSP ROM with a wrapping 13-bit address: trailing bytes overwrite the start of the program (MEASURED 2026-07-27 on jtcps15, black screen; the CPS+ `dump_end` logic in `jtframe_mister_dwnld.v` exists because of it) |
| Header readers | One unit for every field under every capability (`build_controls.verify_images`, the CPS+ pack pointer at bytes 8-9, the upstream generator all count KiB) | A unit that depends on the marker, which every reader must parse first |
| Loader RTL | Three region bounds change | Every compare and every region offset changes unit |
| Size check for the slice | Lost: the top region has no end field (bounded at download) | Kept |
| MRA | `dl-1425.bin` moves in front of the graphics interleaves | Stock part order |

Limits carried forward: the CPS+ pack pointer (image bytes 8-9, 1 KiB units,
16 bits) cannot address a pack appended to an image above 64 MiB; VS2A has no
arranged pack (D5, out of scope), so the flat images ship without one, and a
future pack on such an image needs its own header fix. The DSP address latch
still updates its offset half (parallel bus strobe) and its bank half (address
bus cycle) at different times, so the PCM slot sees transient addresses that
pair one voice's bank with the next voice's offset; the stock core has the
same transients, they only cost SDRAM reads, and `tb_qsnd` treats them as
such.

Tests (`run_gate.py`, all under `tests/`):

- `qsound text`: the four files of 0006 preprocess byte-identically without
  `CPS2_QSND24` to the pinned revision plus 0001-0005 under the stock, program
  and objext macro sets (`jtcps15_sound.v`, which only 0006 touches, also to
  the pinned revision itself; 0001 and 0003 already changed unguarded text in
  the other three, so the pinned revision is not their reference), differ
  with the macro, and an unguarded one-token mutation of each file is caught.
- `lint`: the complete `jtcps2_game` with the full profile.
- `tb_loader.sv`, `PASS loader qsound` / `loader qsound off`: marker `07` in
  the flat order maps 16 MiB of samples to bank 1 words `0..0x7fffff`, 8 KiB of
  firmware to the DSP program port before the graphics, 40 MiB of graphics with
  the 0003 scramble and slice rule of which the last 270,400 bytes lie above
  the 64 MiB download boundary (a 26-bit truncation puts them into the CPU
  region: checked by mutation while the test was written), bytes past 40 MiB
  and the top 27-bit address dropped; `05` stops the graphics at 32 MiB; an
  8 MiB sample region, a 16 KiB or misaligned firmware region, a 4 MiB CPU
  region, the stock order with `05`/`07`, masks `04`, `06`, `0f` and every
  single-bit mutation of `43320107` fail closed (only `05` survives); `01` and
  `03` never turn the capability on; the stock order with 16 MiB of samples
  under `01` keeps the stock layout and sends nothing above 64 MiB to SDRAM;
  a new download clears all three.
- `tb_qsnd.sv`: the real download router inside `jtcps1_sdram` loads a sparse
  16 MiB library through `jtframe_sdram64` (`AW = 24`) into the two chip
  models, and `jtcps15_sound`'s real address latch drives `jtcps1_sdram`'s PCM
  slot exactly as `jtcps2_game` wires it. Forced-bus run (no ROM needed): the
  DSP16 stays in reset and its bus is forced to the cycles a sample read
  produces (offset on the parallel bus with the `pods_n` strobe, `0x8000|bank`
  on the address bus with `cen_cko`); all 256 bank bytes at six offsets per
  bank (both ends of each bank and the signed-16-bit boundary) read back the
  downloaded byte, which differs between bank `b` and `b^0x80`, and two never
  downloaded offsets per bank read the chip pattern of the exact word. Marker
  `07`: banks `0x80..0xff` read the upper 8 MiB; marker `01` in the stock order
  with the same 16 MiB region: they mirror banks `0x00..0x7f` byte for byte
  with no burst above 8 MiB; marker `05` as `07`. Chip 1 is never read, no
  bank other than 1 is touched after reset. Firmware run (`+FIRMWARE`, with the
  game-hook gate, which has `qsound.zip`): the first 8 KiB of `dl-1425.bin`
  go through the loader's firmware region in the flat order into `jtdsp16`,
  the Z80 runs a 40-byte program from the testbench that releases the DSP,
  waits for its ready flag and writes the stock key-on registers of two voices
  (bank `0x80` offset `0x1234`, bank `0xff` offset `0xff00`, end `0xffff`,
  loop 0, rate 0), and the real DSP program then reads those two samples every
  period: bank 1 words `0x40091a` and `0x7fff80` with the capability on (never
  the bank-`0x7f` mirror word), and after a marker-`01` header alone, the DSP
  keeping its registers, words `0x00091a` and `0x3fff80` with no fetch above
  8 MiB.
- Mutations: `+MUTATE=latch` holds bit 23 low before the PCM slot (the stock
  7-bit latch) and `+MUTATE=mirror` forces the capability on while the header
  says off; each must fail `tb_qsnd` (`run_gate.py` requires both and records
  the failing assertion).
- `tb_program.sv`: the CPU test now models the 68K's QSound port (the Z80 bus
  grant, the driver's ready mark `0x77` at Z80 `0xcfff`, every write logged)
  and, with `+QSCMDS`, checks the sound commands a hook posts in order; the
  earlier hooks must post none.

Diagnostic images (`build_controls.py --machine vsav2`, RBF
`jtcps2-prg8-objext`): **`qsound`**, marker `07` in the flat order, the 16 MiB
library whose upper 8 MiB (`prg8_vsav2_qsound_samples.bin`) carries the two
tones of the D3 experiment (1 kHz one-shot at bank `0x80` offset 0, 1502.4 Hz
loop at bank `0xff` offset `0xff00`), `dl-1425.bin` listed before the graphics
interleaves, the 40 MiB graphics region with the slice pattern; and
**`qsmirror`**, marker `01`, the same library, tones and hook in the stock
order (56.25 MiB). Both repoint two descriptor rows of the stock Z80 driver
at the tones by MRA `<patch>` elements (`vs2.01` rows 63 and 54, commands
`0x0112` and `0x0110`, 7 bytes) and share the reset hook
`diagnostics/qsound_hook.s` (4 encrypted vector bytes changed, as for `hook`),
which draws three rows of objects, restarts the Z80 through output port
`0x804040` bit 3 (jtcps2 and MAME both hold the Z80 in reset while it is
clear), performs the game's own boot handshake with the driver (`0x619ffb` =
`0x88` is what lets its interrupt handler take commands at all, `0x619ffd` =
`0xff`, `0x619fff` = `0xff`; MEASURED in the HBMAME model, where the hook was
silent until it did) and posts the game's preamble `00e0 ff05 ff00` followed
by `0112 0110 ff00 0112 0110 ff00`. **What a human should see and hear** on
the 0006 core with `qsound` for about five seconds before Vampire Savior 2
boots: row 1 (`y=0x30`) the game's own art at codes `0x0100-0x0107` (possibly
blank); row 2 (`y=0x50`) the same codes through the alias, eight solid color
blocks from the slice pattern (blue, green, red, cyan, magenta, yellow, white,
grey); row 3 (`y=0x70`) codes `0xfff1-0xfff8` through the alias, the same
eight colors: every byte of those tiles was downloaded above the 64 MiB
boundary of the image, so a core that truncates the download address shows
them wrong or does not boot at all; and a 1 kHz beep of half a second, a
1.5 kHz tone of about a second, a pause, and the pair again. With `qsmirror`
on the same core rows 2 and 3 show the game's art (the alias is a plain
mirror) and the commands play the stock library's mirror of those banks (bank
`0x00` offset 0 and bank `0x7f` offset `0xff00`: faint stock content, then
silence) instead of the tones; the game then boots as `hook` does. On a core
without 0006 (the round-3 `objext` RBF, or `program`) `qsound` must not boot at
all (marker `07` is rejected, so the reordered image misloads and the reset
vector points into a closed window) while `qsmirror` behaves exactly as on the
0006 core. The RTL hook run (`+QSCMDS`, hold unit overridden to 2) checks
the writes reach their targets and the game entry is reached, not what it
sounds like; the HBMAME LLE check below did the listening.

Model check (`model/run_qsound_control.py`, record
`model/qsound_control_validation.json`, probe `model/qsound_control_probe.lua`):
the `qsound` hook, driver patch and upper library as the MRA carries them, on
`vsav2evoq` (MAME's LLE QSound, the real dl-1425 program, 16 MiB region) and,
as the emulator's stand-in for a core without the capability, on `vsav2evo`
(8 MiB region, which the device mirrors). MEASURED 2026-09-29: the restarted
driver acknowledges the hook's first post 1.06 s after the reset release, each
of the four tone commands is followed by its tone (1002.3 Hz at -24.2 dBFS,
77 dB above the median spectrum; 1505.9 Hz at -41 to -44 dBFS, 57-59 dB), the
DSP fetched banks `0x80` (50,509 reads) and `0xff` (245,463) and nothing else
above 8 MiB, and the game posted its own commands afterwards (it booted); on
the 8 MiB region the same commands produced the stock content at bank `0x00`
(3369 Hz, -46 dBFS) and silence, no tone. Two hook revisions failed this check
before the third passed: without the `0x88` control byte the driver never
acknowledged, and with the control bytes written the instant the driver's
ready mark was seen, a retained mark from before the reset let the fresh
driver's own `0x77` land on top of the `0xff` it waits for (the game avoids
this by its shared-RAM test); the hook now waits a fixed unit after the
release before writing them.

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
64 MiB controller and on the XL controller, the XL match mutation, `tb_obj`
through the real controller, the flat QSound text identity, `tb_qsnd` and its
two mutations; with `--with-game-hook`, `tb_qsnd` again with the real DSP
program from `qsound.zip`). Every mutation must fail. It requires
Python 3, Git, a C++ compiler, make and Verilator; game controls also use Go
to rebuild the pinned upstream image assembler. The default output directory
is disposable; nothing in it is a source input. Existing source caches with
unknown edits are rejected.

Controls exist for two machines (`build_controls.py --machine`): `sfa3`
(baseline, legacy, enabled, hook) and `vsav2` (the same four plus `hook2`,
`hook3`, `slice`, `qsound` and `qsmirror`).
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
own `sdram_bank64` tests use.

FPGA run 36621029996 (commit `aa2ba8a`, patches 0001–0004) then built all
three profiles: baseline setup slack +0.044 ns, hold +0.225 ns (RBF
`f64478d4…`, unchanged), `program` setup +0.086 ns, hold +0.244 ns
(`11978c83…`), `objext` setup +0.449 ns, hold +0.205 ns (`6fe517aa…`,
3,406,996 bytes; 19,724 ALMs, 237 M10K blocks). `collect_build.py`
first refused the `objext` profile: its timing-constraint coverage differed
from the baseline by exactly one port, `SDRAM_nCS`, newly an unconstrained
output (+1 port, +1 path; SDC files, clocks, critical warnings and every other
row equal). Reviewed and packaged with the finding on record
(`--accept-coverage-change objext:SDRAM_nCS:…`, kit `48cb3eac…`, record
`quartus_build.json`, `coverage_review`); the `objext` RBF went into the
round-3 staging folder for the slice diagnostic and the VS2A Phase 2 slice
image. Patch 0005 (next section) is the constraint that finding asked for.

## 2026-09-29: patch 0005, chip-select constraint

`run_gate.py --with-game-hook --machine vsav2` from the verified cache, which
`prepare.py` advanced by 0005 (exit 0, 44 PASS lines): every earlier gate
unchanged, plus **sdc** (the `SDRAM_nCS` output-delay pair names the
`SDRAM_CLK` generated clock and a `sys_top` port with the datasheet figures;
the upstream file and four mutations are rejected). Exported with
`export_core.py --from-branch codex/cps2-program-capacity --commit` (the
export now finds the patches a branch already carries by comparing its whole
delta from the pinned revision with the series' cumulative deltas, since a
per-patch reverse `git apply --check` stops working once a later patch touches
the same hunks) as commit `9997238`, pushed, and FPGA run 36643810857
dispatched for the three profiles.

Run 36643810857 passed all three profiles and `collect_build.py 36643810857`
packaged it with no override: timing-constraint coverage is identical to the
baseline again. The `SDRAM_CLK` rows of the `objext` STA summary, which are
the `SDRAM_nCS` output path alone, read **setup +3.416 ns, hold +3.531 ns**
(MEASURED, slow-corner analysis). U1 meets the chip's own `tIS`/`tIH` with
3.4 ns to spare, and U2 tolerates up to 3.416 ns of inverter delay: the
LVC1G04 worst case is 3.3 ns at 15 pF, and one CS# input plus a short trace
loads it well below 15 pF (INFERRED from the schematic; 4.2 ns applies only at
30–50 pF). Everything else equals run 36621029996: `objext` setup +0.449 ns,
hold +0.205 ns, 19,724 ALMs, 237 M10K blocks; `program` setup +0.086 ns;
baseline RBF unchanged. Kit `d1ca1ab5…`; the `objext` RBF `272d42d3…` replaced
the run 36621029996 core in the round-3 folder (same logic; the new pin is now
analyzed). Record `quartus_build.json`; the 0001–0004 build is kept as
`quartus_build_36621029996.json`.

## 2026-09-29: patch 0006, flat 24-bit QSound

`run_gate.py --with-game-hook --machine vsav2` from the verified cache, which
`prepare.py` advanced by 0006 (exit 0, **60 PASS lines**: the 44 of 0005
unchanged, with the lint line now naming `CPS2_QSND24`, plus 16), then
`--with-game-hook` for sfa3 (exit 0, 53 lines). The new lines verbatim:

- `PASS loader qsound: marker 07 = program window + object slice + flat QSound: 1024 sample mappings (16 MiB to bank 1), 8192 firmware bytes before the graphics, 2563 graphics mappings of which 17 above the 64 MiB download boundary, bytes past 40 MiB dropped`
- `PASS loader qsound off: 05 = flat QSound without the slice (graphics stop at 32 MiB), 8 MiB samples / 16 KiB or misaligned firmware / 4 MiB CPU / stock order / masks 04 06 0f and every single-bit mutation of 07 fail closed (05 alone survives), capability off keeps the stock layout with 16 MiB of samples, reload clears`
- `PASS qsound text: the 4 files of patch 0006 preprocess byte-identically to the 0001-0005 series without CPS2_QSND24 under the stock, program and objext macro sets (jtcps15_sound.v also to the pinned upstream), differ with it, and an unguarded mutation of each is caught`
- `PASS qsnd flat: marker 07, 256 banks x 6 downloaded offsets read back f(bank<<16|offset) through the DSP latch, the PCM slot, jtframe_sdram64 and chip 0 bank 1 (2048 fetches, 512 of them never downloaded and matching the chip pattern at the exact word, 1787 SDRAM bursts, 895 from the upper 8 MiB)`
- `PASS qsnd mirror: marker 01 with the same 16 MiB region in the stock order, banks 0x80..0xff read banks 0x00..0x7f byte for byte (2048 fetches, 512 pattern fetches at the mirrored word, 0 upper-half bursts)`
- `PASS qsnd flat05: marker 05 (no slice) reads the upper 8 MiB as marker 07 does (2048 fetches)`
- `PASS qsnd: flat 24-bit QSound sample address through the DSP latch, the capability mask, the PCM slot and the 128 MiB controller: 5373 bank-1 bursts in total, chip 1 never read, 3072 download words all in bank 1`
- `PASS mutation: the stock 7-bit bank latch (bit 23 held low) makes tb_qsnd fail: [159123390000] %Fatal: tb_qsnd.sv:340: Assertion failed in tb_qsnd.sweep: flat: bank 80 offset 0000 read a5, expected 70 (library byte 800000)`
- `PASS mutation: the capability forced on while the header says off makes tb_qsnd fail: [159630620000] %Fatal: tb_qsnd.sv:340: Assertion failed in tb_qsnd.sweep: mirror: bank 80 offset 0000 read 70, expected a5 (library byte 000000)`
- `PASS qsnd firmware flat: dl-1425 on jtdsp16, stock key-on registers with bank bytes 0x80 and 0xff, fetched bank 1 words 40091a (105 times) and 7fff80 (100 times) in the upper 8 MiB of chip 0 through the real latch, slot and controller, never the bank-0x7f mirror word; 703 bank-1 bursts, 413 above 8 MiB`
- `PASS qsnd firmware mirror: capability off, the same DSP voices read bank 1 words 00091a (100 times) and 3fff80 (101 times), banks 0x00 and 0x7f, no fetch above 8 MiB`
- `PASS qsnd: real DSP program, 1338 bank-1 bursts in total, chip 1 never read`
- `PASS game hook sound: 9 commands posted at the QSound port in the expected order (00e0ff05ff0001120110ff0001120110ff00), 31 QSound writes` and the usual `PASS game hook` line, for `qsound` and again for `qsmirror`.

The upstream MRA assembly line grew "flat QSound pair predicted byte for byte":
`build_controls.verify_images` now predicts the two images whole from the
baseline's pieces (`qsound` 67,379,264 B, `qsmirror` 58,990,656 B) and the
upstream `mra2rom` produced exactly those bytes, so the pinned image assembler
accepts a 64.25 MiB image and the moved firmware part. While the loader test
was written, a deliberate 26-bit truncation of the region compare made it
fail at graphics offset `0x27c0000` (bank 0 word `0x1000`: the CPU region),
the hazard the 27-bit decode removes. The `enabled`, `hook` and `hook2` image
digests differ from the 2026-09-28 record because their shared extension
carries the `hook3` hold count since that control was added earlier on
2026-09-29 (`build_controls.extension_image`); `validation.json` now records
the current digests. Patch sha256
`2c13942a3ee7d3a96ab418445b150bf8c921e556ea07fa5f7e3ac701e7c5fd32`
(132 insertions, 2 deletions in four files). The HBMAME LLE check of the
`qsound` hook passed on the third hook revision (see "Model check" above).
No FPGA build carries 0006 yet: `build_cores.yml` adds `-d CPS2_QSND24` to
the `objext` profile and `collect_build.py` expects it only in builds that
carry the patch, so earlier runs stay collectable.

## Remaining acceptance

- Build the `objext` profile with 0006 (`export_core.py --from-branch
  codex/cps2-program-capacity --commit`, dispatch, `collect_build.py`), then
  run the vsav2 `qsound` and `qsmirror` controls on the 128 MiB module
  (HARDWARE.md): the audible tones, the third object row from above 64 MiB,
  and the mirror are hardware-only checks; `qsound` on the run 36643810857
  `objext` core must not boot.

- Run the vsav2 `slice` and `hook` controls on the 128 MiB module with the
  run 36643810857 `objext` core (HARDWARE.md): the two-chip timing, the
  inverter delay on U2's CS# and U2's refresh are hardware-only checks.
- The chip-select timing is closed on paper (run 36643810857: +3.416 ns setup
  covers the LVC1G04's 3.3 ns worst case at 15 pF); signal integrity with two
  loads and U2's refresh remain hardware checks.

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
