# Benchmark results — espice vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| devices/hfet_inverter | 119.61ms | 116.95ms | 19.42ms | skip | 0.2x | 0.2x | 15.5 | 12.3 | - | 2.33e0 | 1.78e0 | FAIL | 2.33e0 | 1.78e0 | FAIL |
