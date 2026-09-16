* Physical folding of colored noise through a periodic multiplier
* KNOWN GAP: the behavioral-source compiler only supports a limited single-control polynomial subset.
* This correctness test should currently fail; implement support to match the expected output.
* KNOWN GAP: periodic noise must distinguish genuine frequency conversion from an LTI circuit; extra LTI sidebands must not add noise.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: noise_multiplier_1.expected.json
Vin in 0 AC 1
R1 in noisy 1k
C1 noisy 0 1u
Vlo lo 0 SIN(0 1 1k 0 0 90)
Bout out 0 V=V(noisy)*V(lo)
Rload out 0 1k
.pnoise v(out) Vin dec 3 10 100 1k 3
.end
