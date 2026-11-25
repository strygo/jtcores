# 2,048-track CPS+ index (private Cyberbots EX core)

Extension of the private 1,024-track core 18cc59d30ab0ca7b901cae2c67278fa291a141a1 (the combined
candidate b7cfcc1ba plus 0022, `CPSPLUS_TRK1024`), compiled with
`CPSPLUS_TRK2048` in place of `CPSPLUS_TRK1024`.  Patch 0023 sets
`cpsplus_top`'s default `TRK_AW` to 11 under the new macro: the
arranged-audio pack player's track index BRAM holds 2,048 entries (8,192 x
64 bits, 64 KB) instead of 1,024 (32 KB) or 128 (4 KB).  Every track-count
width in `cpsplus_ddr` derives from `TRK_AW` (index addresses, index word
count, the `track_count` and index-size compares); the trigger row's 12-bit
track field and the 12-bit event path already span 2,048 tracks.  A pack
with more than 2,048 tracks is refused (status 6), and a play for a track at
or past the pack's track count is ignored.  `CPSPLUS_TRK2048` takes
precedence when both macros are set.

The rbf is named `jtcps2-cpsplus-cybotsex_<date>.rbf` so it never matches the common
`jtcps2-cpsplus_*` binding.  For Cyberbots EX only until it is verified and
folded into the shared core.  Without `CPSPLUS_TRK2048` the file
preprocesses to the 18cc59d30 source (and, without either macro, to the
b7cfcc1ba source).  This candidate has no hardware approval or
production adoption.
