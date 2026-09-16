* Linear DC sweep of source voltage across a divider.
* Expected results: bench_dc_sweep_vin_sweep.expected.json
* Origin: benchmark/fixtures/dc_sweep/vin_sweep/circuit.sp
V1 in 0 DC 0
R1 in out 1k
R2 out 0 3k
.dc V1 0 10 0.5
.end
