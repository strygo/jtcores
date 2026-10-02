# Native32 CPS-2 capacity development core

This isolated source export builds the 8 MiB program / 64 MiB graphics /
32 MiB native-sample machine on 128 MiB SDRAM. It preserves native clocks,
QSound firmware, voices, tile/object formats and arbitration. No CPK support
is added. Native version 2 and legacy images retain their sample masks.

The complete twelve-patch series, pinned base/submodules, functional RTL
receipt and source manifest are included here. Run `verify_export.py --root`
against the checkout before building. It replays every patch and rejects
undeclared tree changes. No Capcom checkout or prior scratch output is needed.

The dispatch-only workflow compares native128 (16 MiB, ninth-bit macro off)
and native32 (32 MiB, CPS2_QSND32 enabled). Both retain the full graphics and
bounded loader features. RBF names are distinct from installed production
cores. Passing reported timing does not establish electrical SDRAM timing
or physical acceptance; external timing coverage must be reviewed as well.

The existing VS2 Arrange and earlier core branches are separate. This export
is a hardware qualification candidate, not a released game or frozen image ABI.
