# 1,024-track CPS+ index (private Cyberbots EX core)

Extension of the combined candidate source b7cfcc1ba89df88466dd98e26a0704b60d844653 (mapped pause, 0020
program windows, 0021 1 MiB Z80), compiled with `CPSPLUS_TRK1024` as well.
The macro sets `cpsplus_top`'s default `TRK_AW` to 10: the arranged-audio
pack player's track index BRAM holds 1,024 entries (4,096 x 64 bits, 32 KB)
instead of 128 (4 KB).  Every track-count width in `cpsplus_ddr` derives
from `TRK_AW` (index addresses, index word count, the `track_count` and
index-size compares); the trigger row's 12-bit track field already spans
1,024 tracks.  A pack with more than 1,024 tracks is refused (status 6), and
a play for a track at or past the pack's track count is ignored.

The rbf is named `jtcps2-cpsplus-cybotsex_<date>.rbf` so it never matches the common
`jtcps2-cpsplus_*` binding.  For Cyberbots EX only until it is verified and
folded into the shared core.  Without `CPSPLUS_TRK1024` the file
preprocesses to the b7cfcc1ba source.  This candidate has no hardware
approval or production adoption.
