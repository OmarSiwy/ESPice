* Full-wave diode bridge feeding a resistive load: four-junction convergence.
* Expected results: bench_diode_bridge.expected.json
* Origin: benchmark/fixtures/convergence/diode_bridge/circuit.sp
* The source's low side is node 0: without any ground reference the MNA
* matrix is singular along the all-ones vector and both simulators report
* an arbitrary common mode (espice and ngspice agreed on every differential
* quantity to 2.6 uV while the "error" was hundreds of volts of null-space).
Vac ap 0 DC 5
D1 ap p DMOD
D2 n ap DMOD
D3 0 p DMOD
D4 n 0 DMOD
RL p n 1k
.model DMOD D(IS=1e-14 N=1.2)
.op
.end
