* BJT differential pair with resistive emitter tail to a negative rail.
* Expected results: bench_analog_diff_pair.expected.json
* Origin: benchmark/fixtures/analog/diff_pair/circuit.sp
* Resistive tail (instead of an ideal current source) gives a well-defined
* DC operating point that converges with plain Newton.
VCC vcc 0 DC 5
VEE vee 0 DC -5
Vp inp 0 DC 0.1
Vn inn 0 DC -0.1
RCp vcc cp 4.7k
RCn vcc cn 4.7k
RT tail vee 4.7k
Q1 cp inp tail QN
Q2 cn inn tail QN
.model QN NPN(IS=1e-16 BF=100)
.op
.end
