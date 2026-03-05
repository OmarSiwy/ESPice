* Shunt voltage regulator: series resistor with diode clamp to a bias rail.
* Expected results: bench_power_zener_reg.expected.json
* Origin: benchmark/fixtures/power/zener_reg/circuit.sp
Vsupply sup 0 DC 12
Rseries sup out 220
Dz out ref DZ
Vref ref 0 DC 5.1
Rload out 0 1k
.model DZ D(IS=1e-12 N=1)
.dc Vsupply 6 18 0.5
.end
