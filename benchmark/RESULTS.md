# Benchmark results — espice vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| convergence/diode_bridge | 8.55ms | 6.30ms | 8.36ms | skip | 1.0x | 1.3x | 5.2 | 12.0 | - | 2.75e-7 | 2.75e-7 | PASS | 2.75e-7 | 2.75e-7 | PASS |
| convergence/high_gain_fb | 5.53ms | 5.88ms | 13.12ms | skip | 2.4x | 2.2x | 4.8 | 12.0 | - | 1.11e-16 | 1.11e-16 | PASS | 1.11e-16 | 1.11e-16 | PASS |
| convergence/schmitt | 6.21ms | 5.71ms | 15.97ms | skip | 2.6x | 2.8x | 4.8 | 12.2 | - | 3.25e-12 | 3.25e-12 | PASS | 3.25e-12 | 3.25e-12 | PASS |
| devices/b3soipd | 8.03ms | 7.76ms | 9.06ms | skip | 1.1x | 1.2x | 6.8 | 12.6 | - | 3.28e-5 | 3.28e-5 | PASS | 3.28e-5 | 3.28e-5 | PASS |
| devices/b4soi | 7.82ms | 7.34ms | 16.41ms | skip | 2.1x | 2.2x | 6.8 | 12.1 | - | 7.79e-4 | 7.79e-4 | PASS | 7.79e-4 | 7.79e-4 | PASS |
| devices/hicum2 | 6.90ms | 6.30ms | 11.82ms | skip | 1.7x | 1.9x | 6.1 | 12.2 | - | 3.71e-10 | 3.71e-10 | PASS | 3.71e-10 | 3.71e-10 | PASS |
| devices/hicum2_gummel | 14.13ms | 13.47ms | 13.42ms | skip | 0.9x | 1.0x | 6.0 | 12.2 | - | 2.70e-12 | 2.38e-12 | PASS | 2.70e-12 | 2.38e-12 | PASS |
| devices/hicum2_output | 41.26ms | 45.58ms | 22.28ms | skip | 0.5x | 0.5x | 6.2 | 12.1 | - | 4.30e-12 | 2.24e-12 | PASS | 4.30e-12 | 2.24e-12 | PASS |
