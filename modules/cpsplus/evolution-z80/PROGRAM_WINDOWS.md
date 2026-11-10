# Program windows candidate

Extension of approved source 296a113d7c1c9395bb1e65aa839bf57a899619c9 (mapped pause), compiled with
`CPS2_PRG12`. A native image whose header declares a 12 MiB CPU region
(header byte 1 = 0x30; every later region 4 MiB higher) gets two more
plaintext, read-only 68000 program windows:

| Window | CPU bytes | CPU-region offset | SDRAM bank 0 bytes |
|---|---|---|---|
| E | e00000-feffff | 800000-9effff | c00000-deffff |
| F | 500000-5fffff | a00000-afffff | e00000-efffff |

Region 9f0000-9fffff and b00000-bfffff are unreachable padding. Window F
takes the one-wait cycle of the rest of the program ROM. Every existing
header keeps its bytes and meaning: without the profile neither window
decodes, the CPU load cap stays 8 MiB and the physical mapping is unchanged.
Without `CPS2_PRG12` the six files preprocess to the approved source.
No scroll, Z80 capacity, sample, music or game-clock change.
This candidate has no fitter result, hardware approval or production adoption.
