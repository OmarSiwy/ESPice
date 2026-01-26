# Benchmark results — espice vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| devices/mesa_inverter | 54.19ms | 66.46ms | 12.13ms | skip | 0.2x | 0.2x | 16.9 | 12.0 | - | 6.36e-4 | 1.55e-4 | PASS | 6.36e-4 | 1.55e-4 | PASS |
