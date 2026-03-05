* Resistively-loaded BJT stage noise output (input-referred noise check).
* Expected results: bench_noise_amp_noise.expected.json
* Origin: benchmark/fixtures/noise/amp_noise/circuit.sp
VCC vcc 0 DC 10
Vin in 0 DC 0.65 AC 1
RB vcc in 100k
RC vcc out 4.7k
Q1 out in 0 QN
.model QN NPN(IS=1e-16 BF=150 KF=1e-14 AF=1)
.noise V(out) Vin dec 10 10 1meg
.end
