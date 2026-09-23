* An I source scales by m= (ngspice isrcload.c), in DC and AC (#73).
* Expected results: isource_multiplier_ngspice.expected.json
* I1 = 1 mA, m=3: v(a) = 3 mA * 1k = 3 V; AC 1 gives |v(a)| = 3k.
I1 0 a DC 1m AC 1 m=3
R1 a 0 1k
.op
.ac lin 1 1k 1k
.end
