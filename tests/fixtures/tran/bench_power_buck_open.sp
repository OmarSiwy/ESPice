* Open-loop buck-converter power stage: switch modeled as PWM voltage source.
* Expected results: bench_power_buck_open.expected.json
* Origin: benchmark/fixtures/power/buck_open/circuit.sp
Vsw sw 0 DC 0 PULSE(0 12 0 10n 10n 4u 10u)
L1 sw out 47u
C1 out 0 100u
Rload out 0 5
Dfw 0 sw DFW
.model DFW D(IS=1e-12 N=1)
.tran 0.1u 200u
.end
