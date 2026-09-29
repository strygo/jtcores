# CPS-2 program capacity hardware test

This is a program-ROM prototype. It retains original CPU/video timing and
graphics/sample capacities. It does not contain HSFA. Use the agreed MiSTer
with 128 MiB SDRAM for acceptance, even though this first program-only change
does not yet use the extra SDRAM address bit.

Copy the kit's `_Arcade` and `games` contents to the corresponding MiSTer SD
directories. The two RBF names use a hyphen so stock `jtcps2` MRAs do not
select them. The kit includes only diagnostic extension data; provide your
canonical `sfa3.zip` and `qsound.zip` in the normal arcade ROM location.
The four test MRAs have separate filenames and set names.

Run the controls in order:

1. **baseline**: original SFA3 image on the pinned CPS+ baseline core.
2. **legacy**: the identical image on the prototype core, extension disabled.
3. **enabled**: original SFA3 program and assets on the prototype, extension
   enabled with additional content loaded into the 4 MiB ROM window.
4. **hook**: four original reset-vector bytes changed. The additional code
   checks its ROM boundaries and returns to SFA3's original reset entry.

For each, record cold boot, attract graphics, native audio, a playable match,
service-menu ROM tests and OSD reset. Record differences against baseline
rather than assuming a ROM-test warning is harmless. The hook's cipher round
trip passes, but full-game ROM-test acceptance has not been established.
The hook deliberately stops if an extension boundary check fails.

For the `vsav2` set (Vampire Savior 2, Japan 970913) the kit carries the
same four controls plus **hook2** and **hook3**: their reset vector points at
plaintext code inside the original 4 MiB window above the key's 1 MiB
encrypted bound. `hook2` proved inconclusive as a negative control on
2026-09-29: it booted on the 2026-09-27 core too, because vsav2 routes every
CPU fault into one handler that restarts the game, so garbled code at boot is
indistinguishable from a normal boot by eye. `hook3` fixes that: its in-window
code first spins about 3.5 s on a hold count, so on a core that executes
plaintext above the bound (patch 0002 and later) the screen stays black for
those seconds before the normal boot, while a core that garbles it (patch
0001 only, or stock jtcps2) boots immediately. Run the vsav2 controls in the
order baseline, legacy, enabled, hook, hook2, hook3, then `hook3` on the old
core (the staging folder ships the 2026-09-27 program RBF as
`jtcps2-prg8-program-old.rbf` with its own MRA, so nothing needs renaming):
expected new core = pause then boot, old core = instant boot. Any other
outcome is a finding to report, not to explain away. The RTL side of this
differential is recorded in the README (the 0002-era testbench fails on
patch 0001 alone at the first page above zero).

The vsav2 kit also carries **slice** (patch 0003, core `jtcps2-prg8-objext.rbf`,
128 MiB SDRAM module required; see the README's "Object extension slice"
for the platform prerequisite). At power-on, before the game boots, the
screen must show for about three seconds: a row of stock tiles (possibly
blank) at the top, a row of eight solid colour blocks below it whose last
block is a 2×2 of four colours, an empty row, and a row identical to the
first; then Vampire Savior 2 starts and plays exactly as `hook`. Record
what each row shows. Missing colour blocks mean the slice download or the
alias path failed; blocks in the third row mean the reserved bank bits
fetch; corrupted stock sprites in the game mean the 40 MiB region overwrote
the library. The `slice` MRA must fail to boot on `jtcps2-prg8-program.rbf`
(marker `03` is rejected there).

The `jtcps2-prg8-objext.rbf` core is the first to drive the 128 MiB module
as two chips (patch 0004): `SDRAM_nCS` low selects U1, high selects U2
through the module's inverter, and every refresh slot refreshes both. Only
the real module can show whether U2 keeps up with the shared bus at 96 MHz:
run the `slice` control, then a long session of `hook` (all its data lives
in U1) and note any corruption that appears only in the slice rows or only
after minutes (U2 refresh or signal integrity) as distinct from immediate
garbage (address or chip-select polarity). Record the module revision
(XS-DS v2.9 or v3.0) and the SDRAM chips' marking. The stock 64 MiB module
must not be used with this core: chip-1 addresses read a floating bus.

Then switch from **hook** to **legacy**, and from the prototype to a normal
stock CPS-2 MRA. Check that the ordinary game boots with its usual graphics,
sound and controls. Record the SDRAM module, MiSTer version, displayed core
identity, each result, and any timing/display/audio differences. A successful
boot alone does not close the compatibility or sustained-load gates.

If baseline fails, resolve the installation/baseline issue before interpreting
the other controls. If only enabled or hook fails, retain that distinction:
it separates core compatibility, ROM placement and the additional code path.

Hardware results must be recorded in the tracked prototype acceptance record
before promoting this core beyond an experiment. The full graphics/sample
extension and the complete HSFA resource budget remain separate milestones.
