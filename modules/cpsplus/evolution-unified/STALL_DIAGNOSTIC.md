# Music stall diagnostic

Based on unified revision 0f72ffa662a551a7593821751de9e529b93dc1d2.
This is an instrumented candidate, not a fix or release qualification.
All music files, decoder, player, reader, arbiter and loader remain unchanged.

Build adds CPSPLUS_DBG and CPSPLUS_STALL_DBG. The final cell (rightmost of
eight) in the cyan row now records whether a sample tick encountered an empty
music FIFO while playing and unpaused. It remains lit after recovery and
clears when the music stack resets. Other overlay cells retain their existing
meaning. A green status square by itself does not prove uninterrupted audio.

Reset before testing Fei Long; after a cutout photograph the overlay before
resetting. A lit sticky cell establishes starvation, not its DDR/clock cause.
A dark cell directs investigation toward commands, fades, resets and mixing.
Instrumentation changes FPGA placement; absence of cutouts is inconclusive.
