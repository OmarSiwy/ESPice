* A v(a,b) output measures the difference, not node a alone
* Expected results: differential_rc.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in a 1k
C1 a 0 1u
R2 b 0 1k
C2 b 0 1u
.hbnoise v(a,b) Vin dec 3 10 10k 1k 3 3
.end
