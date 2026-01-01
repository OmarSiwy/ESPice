# Benchmark results — zpicey vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| devices/bsim2 | 8.49ms | 146.09ms | 15.17ms | skip | 1.8x | 0.1x | 8.3 | 12.0 | - | - | - | - | - | - | - |
