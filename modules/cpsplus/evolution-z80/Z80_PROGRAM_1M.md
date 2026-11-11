# 1 MiB Z80 program candidate

Extension of the program-window source 3b38027e6a29c6498ad25c38af0cedeabd6405b6 (patch 0020 on the mapped-pause
core), compiled with `CPS2_Z80_1M` as well as `CPS2_PRG12`. A native image
whose header gives a Z80 region of 1 MiB (header byte 3 - byte 1 = 4: byte 3
is 0x24 with the 8 MiB CPU region, 0x34 with the 12 MiB one; every later
region 0x300 KiB higher, the native end 0xc0000 higher) gets a sixth Z80 bank
bit:

| Z80 program | Banks | Selections decoded to bank 0 | Status D007 bits 6-0 |
|---|---|---|---|
| 256 KiB (stock, byte 3 - byte 1 = 1) | 0-15 (bits 3-0) | none | 1, 1, 1, bank[3:0] |
| 512 KiB (= 2) | 0-29 | 30, 31 | 1, 1, bank[4:0] |
| 1 MiB (= 4) | 0-61 | 62, 63 | 1, bank[5:0] |

The banked window stays 16 KiB at 8000-bfff (`rom_addr = {bank, A[13:0]} + 8000`,
now 20 bits); the fixed 32 KiB is unchanged and bit 7 of the latch still
controls the QSound DSP reset. The program fills bank-0 bytes 700000-7fffff
(SND_OFFSET unchanged, Z80_AW 20). Every existing header keeps its bytes and
meaning, and the program-window profile composes with it. Without
`CPS2_Z80_1M` the six files preprocess to the 0020 source.
This candidate has no fitter result, hardware approval or production adoption.
