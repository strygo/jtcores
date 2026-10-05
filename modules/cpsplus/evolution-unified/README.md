# Unified CPS-2 development source

One build supports legacy native audio, legacy appended CPS+ music, enhanced
native16/native32 images and enhanced images with separately staged CPS+ music.
This source replaces no production release and changes no game ROMs.

The export manifest records all sixteen applied patches, changed source,
workflow and bundle files, pinned base/submodules and functional receipts.
`verify_export.py` replays the complete series and rejects changes anywhere
outside that declared tree. It is self-contained; no Capcom checkout or existing
scratch cache is required.

The first fourteen patches retain their functional qualifications. Patch 15
repairs only the synthesis file list: the pinned `jtcore` command does
not forward its CLI macros to `jtframe files`, so the loader must be listed
unconditionally. Its instantiation remains conditional in the HDL. The exporter
checks every qualified runtime file against its receipt, rebuilds the
actual JTFRAME generator and checks both default and explicit-macro source
lists. The workflow repeats that check before Quartus. The source-list receipt
also rejects omitted, duplicated and incorrectly typed loader assignments.

Patch 16 repairs the reader's measured setup path by latching final-burst tail
information before returned data reaches the audio buffers. It changes only
`cpsplus_ddr.v`, adds no read latency and leaves clocks and constraints intact.
`M4_READER_TIMING_RESULT.json` records a focused comparison of all 40 public
outputs cycle by cycle against the exact reader used by the prior integration
receipts. It covers 169 synthetic/boundary cases, all 32 accepted pack metadata
sets, extent-disabled legacy operation and a rejected stale-tail-byte mutation.
Macro-off tokens remain identical. The exporter permits only this one file to
differ from the earlier integration receipts and checks its precise old/new
identities and the complete repaired source set. Native transport and mixed DSP
integration tests were not rerun for this repair; the focused comparison extends
their earlier evidence. Physical timing still requires an accepted FPGA fit.

The dispatch-only workflow builds the CPS+ leg with the expanded memory profile
and unified loader/extent options. The inherited CPS-2 configuration uses 96 MHz
ROM/game clocks and byte-wide HPS transfers. DDR line/frame buffering is disabled
because it would conflict with staging/music at `0x30000000`. Decoder/player,
trigger, volume and mixer retain the accepted CPS+ implementations.

Functional receipts cover pack metadata/bounds, complete native32 transport,
startup/fallback/reset/drain and accepted SFA1 ADX with real native high-bank
DSP voices and graphics/program consumers. They are integration evidence, not
whole-game or physical FPGA acceptance. The CPU-visible capability/status
register remains open. Hardware qualification must include the complete MiSTer
MRA XML/ZIP loading path, legacy controls, both enhanced sample modes, reset and
reload, and supported SDRAM modules.

The candidate artifact is `jtcps2-cpsplus-unified.rbf`; this distinguishes an
unaccepted test from the installed release. The release objective remains one
canonical `jtcps2-cpsplus` RBF after qualification and Steve's release approval.
