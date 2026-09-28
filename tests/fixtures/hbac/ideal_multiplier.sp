* HB AC conversion gain of an ideal multiplier into both adjacent sidebands
* Expected results: ideal_multiplier.expected.json
Vrf rf 0 DC 0 AC 1
Vlo lo 0 SIN(0 1 1k 0 0 90)
Bout out 0 V=V(rf)*V(lo)
Rload out 0 1k
.hbac dec 3 10 100 1k 3
.end
