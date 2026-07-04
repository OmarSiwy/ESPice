* HB AC conversion of a multiplier pumped by two tones into each tone's sidebands
* Expected results: multitone_multiplier.expected.json
Vrf rf 0 DC 0 AC 1
Vlo1 lo1 0 SIN(0 1 1k 0 0 90)
Vlo2 lo2 0 SIN(0 1 1.3k 0 0 90)
Bout out 0 V=V(rf)*(V(lo1)+V(lo2))
Rload out 0 1k
.hb tones=1k 1.3k nharms=1 1
.hbac lin 2 100 200
.end
