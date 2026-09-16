* Sum/difference mixing and DC generation
* KNOWN GAP: QPSS does not yet honor the physical two-tone source spectra.
* This correctness test should currently fail; implement support to match the expected output.
* KNOWN GAP: the behavioral-source compiler only supports a limited single-control polynomial subset.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: square_mixer.expected.json
V1 a 0 SIN(0 1 1000)
V2 b 0 SIN(0 .5 1414.213562373095)
Bout out 0 V=(V(a)+V(b))^2
Rload out 0 1k
.qpss 1000 1414.213562373095 2 2
.end
