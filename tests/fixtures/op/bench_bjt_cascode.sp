* Cascode amplifier: stacked NPN for high output impedance.
* Expected results: bench_bjt_cascode.expected.json
* Origin: benchmark/fixtures/bjt/cascode/circuit.sp
VCC vcc 0 DC 10
Vbias bias 0 DC 5
Vin in 0 DC 0.65
RC vcc out 5k
Q1 mid in 0 QN
Q2 out bias mid QN
.model QN NPN(IS=1e-16 BF=120 VAF=100)
.op
.end
