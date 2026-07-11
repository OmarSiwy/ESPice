# Benchmark results — zpicey vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| verilog/inverter | 71.20ms | 283.54ms | skip | skip | - | - | 13.1 | - | - | - | - | - | - | - | - |
