| Compared with | Decks both ran | ESPice faster | Median speedup | Agree / differ |
|---|---:|---:|---:|---:|
| ngspice | 473 | 466 | 3.3x | 424 / 13 |
| VACASK | 270 | 270 | 3.5x | 234 / 17 |

| Deck | Devices | espice ms | ngspice ms | VACASK ms |
|---|---:|---:|---:|---:|
| `stress/scaling_rc_ladder_100k.sp` | 200,001 | 5,431 | 16,371 | 19,907 |
| `stress/sweep_opamp_wl_5000.sp` | 30,004 | 616 | 8,191 | 4,433 |
| `stress/scaling_resistor_grid_100x100.sp` | 19,802 | 67 | 7,758 | 204 |
| `stress/scaling_inverter_chain_4k.sp` | 12,002 | 6,654 | 15,811 | 271,530 |
| `op/controlled_source_scaling.sp` | 8,192 | 16 | 64 | 78 |
| `stress/scaling_parallel_inverters_2000.sp` | 6,002 | 1,500 | 1,575 | 7,107 |
| `stress/scaling_rc_ladder_1k.sp` | 2,001 | 28 | 64 | 234 |
| `stress/scaling_resistor_grid_32x32.sp` | 1,986 | 9 | 62 | 35 |
