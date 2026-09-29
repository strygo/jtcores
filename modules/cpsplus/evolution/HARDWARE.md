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
same four controls plus **hook2**: its reset vector points at plaintext code
inside the original 4 MiB window above the key's 1 MiB encrypted bound. With
the 2026-09-27 prototype RBF (patch 0001 only) hook2 must fail to start,
because that core decrypts every page; with the patch-0002 RBF all five
vsav2 controls must boot identically. Run vsav2 in the order baseline,
legacy, enabled, hook, hook2 and record the same observations as for SFA3.
A hook2 that boots on the old RBF, or fails on the new one, is a finding to
report, not to explain away.

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
