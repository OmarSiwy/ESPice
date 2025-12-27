# Benchmark results — zpicey vs ngspice vs xyce

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2

| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| adversarial/near_singular | 3.59ms | 252.69ms | 13.64ms | skip | 3.8x | 0.1x | 7.3 | 11.8 | - | 1.67e-1 | 1.67e-1 | FAIL | 1.67e-1 | 1.67e-1 | FAIL |
| devices/resistor | 6.43ms | 241.03ms | 14.97ms | skip | 2.3x | 0.1x | 7.5 | 11.7 | - | 5.33e-16 | 5.33e-16 | PASS | 5.33e-16 | 5.33e-16 | PASS |
