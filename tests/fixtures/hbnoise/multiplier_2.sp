* Physical folding of colored noise through a periodic multiplier
* Expected results: multiplier_2.expected.json
Vin in 0 AC 1
R1 in noisy 1k
C1 noisy 0 1u
Vlo lo 0 SIN(0 2 1k 0 0 90)
Bout out 0 V=V(noisy)*V(lo)
Rload out 0 1k
.hbnoise v(out) Vin dec 3 10 100 1k 3 3
.end
