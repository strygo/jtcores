# Unified CPS-2 development source

One build supports legacy native audio, legacy appended CPS+ music, enhanced
native16/native32 images and enhanced images with separately staged CPS+ music.
This source replaces no production release and changes no game ROMs.

The export manifest records all fourteen applied patches, changed source,
workflow and bundle files, pinned base/submodules and functional receipts.
`verify_export.py` replays the complete series and rejects changes anywhere
outside that declared tree. It is self-contained; no Capcom checkout or existing
scratch cache is required.

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
