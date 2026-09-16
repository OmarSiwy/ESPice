* Diode I-V characteristic via DC sweep of the driving source.
* Expected results: bench_dc_sweep_param_sweep.expected.json
* Origin: benchmark/fixtures/dc_sweep/param_sweep/circuit.sp
V1 a 0 DC 0
R1 a b 50
D1 b 0 DMOD
.model DMOD D(IS=1e-14)
.dc V1 0 1 0.02
.end
