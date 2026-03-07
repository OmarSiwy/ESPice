* Unique nonlinear root over many current scales
* KNOWN GAP: the behavioral-source compiler only supports a limited single-control polynomial subset.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: monotonic_cubic_0p001.expected.json
Iin 0 out 0.001
R1 out 0 1
B1 out 0 I=V(out)^3
.op
.options reltol=1e-7 abstol=1e-15 vntol=1e-12
.end
