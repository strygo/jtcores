# Native capacity core source export

This is an isolated CPS-2 development branch, requiring 128 MiB SDRAM on
MiSTer for enhanced images. It is not a game port or a production release.
The branch retains the pinned CPS+ audio modules unchanged. Appended CPS+
packs are outside the new native-image profile.

The export contains all nine patches, the pinned source/submodule identities,
the functional native-loader qualification receipt and a self-contained source
verifier. Run the verifier from the core checkout before generating build
outputs:

```sh
git submodule update --init modules/fx68k modules/jtdsp16 modules/jteeprom
python3 modules/cpsplus/evolution-capacity/verify_export.py --root "$PWD"
```

The verifier checks all tracked changes against the declared base, replays
the patch series, verifies generated source hashes and rejects dirty or
unexpected files. It does not depend on another checkout or an existing cache.
It requires Python 3 and Git.

The dispatch-only workflow builds two separately named profiles with the
same pinned Quartus container and unchanged fitter script:

- `prototype`: program/object/native sample extensions; full graphics and
  bounded loading disabled. This is the comparison build.
- `native128`: also enables `CPS2_GFX64`, `CPS2_SCREXT` and `CPS2_NATIVE128`.
  It loads 8 MiB program, 256 KiB Z80, 16 MiB native samples, 8 KiB DSP
  firmware and 64 MiB graphics through a checked 128-byte envelope.

Artifacts are named `jtcps2-capacity-prototype.rbf` and
`jtcps2-capacity-native128.rbf`. They must pass compilation, reported timing
and independent artifact review before entering a hardware test kit. Do not
install them over an existing core. These names keep their test MRAs separate
from stock and the earlier program-capacity cores.

The 16 MiB sample limit and the image format remain provisional. Functional
simulation does not prove FPGA timing, native sample playback or board
compatibility. Hardware qualification and title capacity closure are still
required. The qualification receipt records simulation observations only.
