* Independent incommensurate tones and two-sided normalization
* KNOWN GAP: QPSS does not yet honor the physical two-tone source spectra.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: linear_two_tone_2_2.expected.json
V1 a 0 SIN(0 1 1000)
V2 in a SIN(0 0.5 1414.213562373095)
R1 in out 1k
C1 out 0 1u
.qpss 1000 1414.213562373095 2 2
.end
