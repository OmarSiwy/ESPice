* NMOS W/L Optimization Sweep — find W/L for target gm/Id
* Expected results: bench_sweep_nmos_wl_opt.expected.json
* Origin: benchmark/fixtures/sweep/nmos_wl_opt/circuit.sp
.model nch NMOS(level=54)
Vdd vdd 0 DC 1.1
Vgs gate 0 DC 0.5
Vds vdd drain 0
M1 drain gate 0 0 nch W=1u L=0.1u
.dc Vgs 0.2 1.1 0.01
.end
