* LO multiplier conversion gain into both adjacent sidebands
* KNOWN GAP: PAC currently injects a node current instead of honoring the named voltage-source excitation.
* This correctness test should currently fail; implement support to match the expected output.
* KNOWN GAP: the behavioral-source compiler only supports a limited single-control polynomial subset.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: ideal_multiplier_1.expected.json
Vrf rf 0 DC 0 AC 1
Vlo lo 0 SIN(0 1 1k 0 0 90)
Bout out 0 V=V(rf)*V(lo)
Rload out 0 1k
.pac 1k dec 3 10 100
.end
