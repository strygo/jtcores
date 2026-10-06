# CPS+ 512 KiB sound-ROM development source

This checkout is a complete, pinned JTCORES development source export. It
combines the existing unified CPS+ platform with an optional 512 KiB Z80
program/sequence ROM. The CPU clocks, video timing, QSound DSP and existing
music implementation are unchanged. Stock games keep four-bit banking.

Initialize the three pinned submodules, then verify the source before building:

```sh
git submodule update --init modules/fx68k modules/jtdsp16 modules/jteeprom
python3 modules/cpsplus/evolution-z80/verify_export.py --root "$PWD"
```

The included dispatch workflow builds one development core using the pinned
Quartus container. It enables `CPS2_Z80_512` alongside the unified platform
macros and checks timing. The build preset is not a claim that a fitted RBF
or physical hardware has passed; inspect the build result separately.

The native descriptor accepts 256 or 512 KiB Z80 content. Existing 256 KiB
headers retain their bytes and interpretation. Enlarged images move all
following regions by 262,144 bytes and require the new core. Invalid headers,
received extents and bank selections cannot wrap into unrelated memory.
The 512 KiB sound board has a fixed 32 KiB window and 30 banked 16 KiB pages.

The bundle includes the complete patch series, source manifest and software
qualification receipts. `verify_export.py` checks the whole tracked delta,
all file identities, clean pinned submodules and replay against the base.
No copyrighted game content or generated ROM is distributed here.

The `hbmame/` folder supplies the matching consolidated driver, hooks and
upstream revision. Apply the hooks to that pinned HBMAME checkout and copy
the supplied header/driver to their named locations. Synthetic test game
registrations are excluded from those production source files.

Hardware acceptance remains outstanding. Do not load a 512 KiB native image
on an earlier RBF. The new capacity alone does not restore missing game music;
the game must link and qualify its native music resources separately.
