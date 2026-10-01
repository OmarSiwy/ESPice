* RC noise folded through a multiplier pumped by two tones
* Expected results: multitone_multiplier.expected.json
Vin in 0 AC 1
R1 in noisy 1k
C1 noisy 0 1u
Vlo1 lo1 0 SIN(0 1 1k 0 0 90)
Vlo2 lo2 0 SIN(0 1 1.3k 0 0 90)
Bout out 0 V=V(noisy)*(V(lo1)+V(lo2))
Rload out 0 1k
.hb tones=1k 1.3k nharms=1 1
.hbnoise v(out) Vin dec 3 10 100
.end
