# Benchmark results — espice vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bjt/diff_amp | 52.32ms | 50.00ms | 10.27ms | skip | 0.2x | 0.2x | 15.3 | 12.4 | - | 1.05e-6 | 6.37e-7 | PASS | 1.05e-6 | 6.37e-7 | PASS |
