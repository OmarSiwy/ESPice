# Simulator benchmark

- espice: `espice` — espice 0.1.0
- ngspice: `ngspice` — ngspice-45 : Circuit level simulation program
- vacask: `vacask` — This is vacask unknown.
- column espice: ` espice --backend=cpu`

Median of 3 measured runs after one warm-up; milliseconds include process startup and output. VACASK conversion is outside timing.

| Fixture | espice ms | ngspice ms | VACASK ms | espice/ngspice | espice/VACASK | ngspice/VACASK |
|---|---:|---:|---:|---|---|---|
| chain_bsim4_100k.sp | 88443.223 | — | 239510.418 | unavailable | DIFFER | unavailable |
| chain_bsim4_10k.sp | 10060.818 | 143804.916 | — | agree | unavailable | unavailable |
| chain_bsim4_1k.sp | 1697.648 | 3883.648 | 3642.201 | agree | agree | agree |
| chain_psp103_10k.sp | 41324.802 | — | 49138.191 | unavailable | DIFFER | unavailable |
| chain_psp103_1k.sp | 3486.362 | — | 5546.287 | unavailable | DIFFER | unavailable |
| logic_bsim4_10k.sp | 145068.503 | — | — | unavailable | unavailable | unavailable |
| logic_bsim4_1k.sp | 10968.758 | 30749.766 | 27851.721 | agree | agree | agree |
| logic_psp103_10k.sp | — | — | — | unavailable | unavailable | unavailable |
| logic_psp103_1k.sp | 8718.764 | — | 42805.260 | unavailable | DIFFER | unavailable |
| ring_bsim4_100k.sp | 186994.708 | — | 221326.593 | unavailable | agree | unavailable |
| ring_bsim4_10k.sp | 17037.122 | 127201.274 | 47743.574 | agree | agree | agree |
| ring_bsim4_1k.sp | 2689.424 | 6264.906 | 5112.398 | agree | agree | agree |
| ring_psp103_10k.sp | 40384.227 | — | 88124.339 | unavailable | DIFFER | unavailable |
| ring_psp103_1k.sp | 6322.330 | — | 7941.306 | unavailable | DIFFER | unavailable |
| sram_bsim4_10k.sp | 34567.803 | — | 67364.016 | unavailable | DIFFER | unavailable |
| sram_bsim4_1k.sp | 1568.305 | 5693.583 | 2349.564 | agree | agree | agree |
| sram_psp103_10k.sp | — | — | 70468.005 | unavailable | unavailable | unavailable |
| sram_psp103_1k.sp | 3410.031 | — | 3804.391 | unavailable | DIFFER | unavailable |

- chain_bsim4_100k.sp / ngspice: Timeout
- chain_bsim4_10k.sp / VACASK: Timeout
- chain_psp103_10k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- chain_psp103_1k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- logic_bsim4_10k.sp / ngspice: Timeout
- logic_bsim4_10k.sp / VACASK: Timeout
- logic_psp103_10k.sp / espice: Timeout
- logic_psp103_10k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- logic_psp103_10k.sp / VACASK: Timeout
- logic_psp103_1k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- ring_bsim4_100k.sp / ngspice: Timeout
- ring_psp103_10k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- ring_psp103_1k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- sram_bsim4_10k.sp / ngspice: Timeout
- sram_psp103_10k.sp / espice: Timeout
- sram_psp103_10k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- sram_psp103_1k.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
