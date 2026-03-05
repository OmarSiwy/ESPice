* Ensemble MC fixture (README 2.6, load-bearing): 5-transistor BJT op-amp,
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_ensemble_opamp_mc.expected.json
* Origin: benchmark/fixtures/ensemble/opamp_mc/circuit.sp
* unity follower, step response. [sampling] declares 3-sigma mismatch MC over
* the matched pairs (Q1/Q2 input pair, Q3/Q4 mirror); h-dispersion across
* lanes is measured here BEFORE any AoSoA code lands (MIGRATION Step 15).
Vcc vcc 0 DC 12
Vee vee 0 DC -12
Vin in 0 DC 0 PULSE(0 1 10u 1u 1u 200u 500u)
* input differential pair (matched: Q1/Q2)
Q1 c1 in e12 qn
Q2 c2 fb e12 qn
Ree e12 vee 10k
* current-mirror load (matched: Q3/Q4)
Q3 c1 c1 vcc qp
Q4 c2 c1 vcc qp
* output stage
Q5 vcc c2 out qn
Rout out vee 4.7k
* unity feedback
Rfb out fb 1
Cfb fb 0 1p
.model qn NPN(bf=150 is=1e-15)
.model qp PNP(bf=80 is=1e-15)
.tran 1u 500u
.end
