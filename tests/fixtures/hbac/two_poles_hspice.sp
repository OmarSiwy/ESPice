* HSPICE form: .hbac takes its tone from the .hb card
* Expected results: two_poles_hspice.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in a 1k
C1 a 0 1u
Ebuf b 0 a 0 1
R2 b out 1k
C2 out 0 1u
.hb 1k 3
.hbac dec 4 10 10k
.end
