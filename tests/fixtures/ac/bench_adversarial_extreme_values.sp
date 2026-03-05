* Extreme parameter spread: femtofarad cap, teraohm resistor, gigahertz drive.
* Expected results: bench_adversarial_extreme_values.expected.json
* Origin: benchmark/fixtures/adversarial/extreme_values/circuit.sp
* Stresses dynamic range of the f64 stamping and time stepping.
Vin in 0 DC 0 AC 1
R1 in out 1e12
C1 out 0 1e-15
.ac dec 5 1meg 10g
.end
