# Benchmark results — zpicey vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bjt/cascode | skip | skip | 15.51ms | skip | - | - | - | 11.7 | - | - | - | SKIP | - | - | SKIP |
| bjt/common_emitter | 79.96ms | 79.83ms | 8.42ms | skip | 0.1x | 0.1x | 14.4 | 11.9 | - | - | - | - | - | - | - |
| bjt/diff_amp | skip | skip | 8.81ms | skip | - | - | - | 11.8 | - | - | - | SKIP | - | - | SKIP |
