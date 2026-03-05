* DISTO fixture: BJT common-emitter distortion.
* KNOWN GAP: full complex second- and third-harmonic distortion output is not yet exposed.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_disto_bjt_ce.expected.json
* Origin: benchmark/fixtures/disto/bjt_ce/circuit.sp
Vcc vcc 0 DC 12
Vin in 0 DC 0.7 AC 1 DISTOF1 0.01
Rb in b 10k
Rc vcc c 4.7k
Q1 c b 0 qn
.model qn NPN(bf=120 is=1e-15)
.disto dec 10 1k 1meg
.end
