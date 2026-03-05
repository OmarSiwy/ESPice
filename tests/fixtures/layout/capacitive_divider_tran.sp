Capacitor-only island: transient OP must initialize charge before time stepping
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: capacitive_divider_tran.expected.json
* Origin: benchmark/fixtures/layout/capacitive_divider_tran/circuit.sp
V1 in 0 DC 1 PULSE(1 2 1n 10p 10p 2n 4n)
R1 in 0 1k
C1 in island 1p
C2 island 0 1p
.tran 1p 2n
.end
