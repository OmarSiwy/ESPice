* .options rshunt puts a resistor from every node to ground (#11).
* Oracle: ngspice 45. 1 mA into 1k || 1k || (1k + 1k) = 400 ohm gives
* v(n) = 0.4 V, and the 1k-1k divider to n2 gives 0.2 V.
* Expected results: option_rshunt_ngspice.expected.json
I1 0 n 1m
R1 n 0 1k
R2 n n2 1k
.options rshunt=1k
.op
.end
