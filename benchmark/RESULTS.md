# Benchmark results — espice vs ngspice, Xyce and VACASK

## Reference simulators

| column | version | binary |
|---|---|---|
| ngspice | ngspice-44.2 : Circuit level simulation program | `/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice` |
| xyce | Xyce Release 7.10.0-opensource | `/nix/store/7glhfffprbvfz11bi9pd1fr5np8nw5df-xyce-7.10.0/bin/Xyce` |
| vacask | This is vacask unknown. | `/nix/store/g5ial84gcp2da9h7y63r4c6dc1iqip57-vacask-unstable-2026/bin/vacask` |

ngspice runs its DEFAULT solver unless `--ngspice-klu` is passed. That is
deliberate and measured: KLU is slower on every deck in this suite
(parallel_inverters_100 513M -> 555M Ir, mos6_inverter 149M -> 163M,
rc_ladder_10k 2.60G -> 3.98G). KLU's ordering and BTF analysis pay off at
1e5+ unknowns, not on a 105x105 matrix, so the default is ngspice's
STRONGEST configuration here and the reference is not a strawman.

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2; error normalized by max(peak, span, 1).
N/A: unvalidated (unsupported complex/multiple plots, missing signals, or incomplete samples).
SKIP: that reference did not run the fixture (VACASK only runs where a `vacask.sim` deck exists).
GPU timings exclude reported CPU fallback.

| fixture | zp-cpu | zp-gpu | ngspice | xyce | vacask | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | vc-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu | xy | vc |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| tline/cpl3_4_line | 20.84ms | 19.53ms | 29.54ms | skip | skip | 1.4x | 1.5x | 5.2 | 12.2 | - | - | 1.72e0 | 9.21e-1 | N/A | 1.72e0 | 9.21e-1 | N/A | SKIP | SKIP |
| tline/cpl_ibm2 | 13.31ms | 13.34ms | 13.17ms | skip | skip | 1.0x | 1.0x | 4.9 | 12.1 | - | - | 1.28e-1 | 4.26e-2 | N/A | 1.28e-1 | 4.26e-2 | N/A | SKIP | SKIP |
| tline/delay_line | 6.16ms | 6.38ms | 13.75ms | 70.59ms | skip | 2.2x | 2.2x | 5.5 | 11.8 | 55.6 | - | 6.67e-4 | 2.66e-5 | PASS | 6.67e-4 | 2.66e-5 | PASS | N/A | SKIP |
| tline/ideal_tline | 6.26ms | 6.40ms | 13.45ms | 64.66ms | skip | 2.1x | 2.1x | 5.5 | 11.8 | 55.7 | - | 5.93e-16 | 2.09e-17 | PASS | 5.93e-16 | 2.09e-17 | PASS | N/A | SKIP |
| tline/ltra1_1_line | 18.46ms | 18.45ms | 23.71ms | skip | skip | 1.3x | 1.3x | 6.3 | 12.1 | - | - | 2.16e-3 | 3.63e-4 | PASS | 2.16e-3 | 3.63e-4 | PASS | SKIP | SKIP |
| tline/ltra2_2_line | 31.39ms | 24.05ms | 26.90ms | skip | skip | 0.9x | 1.1x | 6.6 | 12.0 | - | - | 9.65e-6 | 1.33e-6 | PASS | 9.65e-6 | 1.33e-6 | PASS | SKIP | SKIP |
| tline/terminated | 5.88ms | 5.65ms | 12.64ms | 99.46ms | skip | 2.1x | 2.2x | 5.5 | 12.0 | 54.6 | - | 1.00e-4 | 5.13e-6 | PASS | 1.00e-4 | 5.13e-6 | PASS | N/A | SKIP |
| tline/txl1_1_line | 7.52ms | 7.28ms | 14.15ms | skip | skip | 1.9x | 1.9x | 6.1 | 12.0 | - | - | 5.70e-3 | 4.28e-4 | N/A | 5.70e-3 | 4.28e-4 | N/A | SKIP | SKIP |
| tline/txl2_3_line | 9.49ms | 9.09ms | 11.99ms | skip | skip | 1.3x | 1.3x | 6.4 | 11.8 | - | - | 5.40e-3 | 3.54e-4 | N/A | 5.40e-3 | 3.54e-4 | N/A | SKIP | SKIP |
| tran/fourbitadder | 41.20ms | 45.36ms | 23.99ms | 87.00ms | skip | 0.6x | 0.5x | 8.0 | 13.0 | 57.8 | - | 3.53e-5 | 8.41e-6 | N/A | 3.53e-5 | 8.41e-6 | N/A | PASS | SKIP |
| tran/rc_pulse | 4.91ms | 4.69ms | 11.71ms | 69.24ms | skip | 2.4x | 2.5x | 4.6 | 11.8 | 55.5 | - | 7.65e-14 | 7.46e-15 | PASS | 7.65e-14 | 7.46e-15 | PASS | PASS | SKIP |
