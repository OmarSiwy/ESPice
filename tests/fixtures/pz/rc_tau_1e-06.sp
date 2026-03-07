* Single RC pole
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rc_tau_1e-06.expected.json
Vin in 0 0
R1 in out 1k
C1 out 0 9.999999999999999e-10
.pz
.end
