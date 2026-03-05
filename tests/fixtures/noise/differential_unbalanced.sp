* Differential noise sums independent resistor-noise powers
* KNOWN GAP: differential analysis output must be resolved as a node difference.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: differential_unbalanced.expected.json
Vin in 0 AC 1
R1 in a 1000
R2 a 0 3000
R3 in b 3000
R4 b 0 1000
.noise v(a,b) Vin dec 3 10 10k
.end
