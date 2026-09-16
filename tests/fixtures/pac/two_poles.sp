* LTI PAC must reduce to the AC voltage-source transfer
* KNOWN GAP: PAC currently injects a node current instead of honoring the named voltage-source excitation.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: two_poles.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in a 1k
C1 a 0 1u
Ebuf b 0 a 0 1
R2 b out 1k
C2 out 0 1u
.pac 1k dec 4 10 10k
.end
