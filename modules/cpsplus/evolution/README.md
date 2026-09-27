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

## Rebuilding and acceptance

From the Capcom repository root:

```
python3 cpsplus/evolution/run_gate.py
python3 cpsplus/evolution/run_gate.py --work cpsplus/evolution/work/clean
python3 cpsplus/evolution/run_gate.py --with-game-hook
```

The command fetches the pinned core and its required submodules, verifies
the source and tracked patch, builds the pinned vasm assembler using the
committed Gold toolchain recipe in a separate cache, and builds/runs the
Verilator tests. It requires Python 3, Git, a C++ compiler, make and
Verilator. The default output directory is disposable; nothing in it is a
source input. Existing source caches with unknown edits are rejected.

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

## Remaining acceptance

- Full-core synthesis, resource/timing comparison and real MiSTer validation.
- Unmodified stock-game controls, then a bounded stock-game extension hook.
- Complete HSFA code/data, RAM and asset budgets before substantial graphics
  and sample expansion work; those proposed capacities remain provisional.

The generic platform tests do not establish that the full HSFA port fits or
meets the original CPU and rendering limits.
