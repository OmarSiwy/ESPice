* LTI PAC must reduce to the AC voltage-source transfer
* KNOWN GAP: PAC currently injects a node current instead of honoring the named voltage-source excitation.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: divider.expected.json
Vin in 0 DC 0 AC 1 SIN(0 1 1k)
R1 in out 1000
R2 out 0 3000
.pac 1k dec 4 10 10k
.end
