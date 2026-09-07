* .options gmin is the junction shunt of every SPICE device (#78).
* Oracle: ngspice 45. D1 sits reverse-biased at 1 V, so i(v1) is
* Is + gmin * 1 V = -1.0e-3 A. Q1's base sits at -1 V, so both of its
* junctions are reverse-biased and their gmin shunts carry 2 mA.
* Expected results: option_gmin_ngspice.expected.json
V1 0 a 1
D1 a 0 dmod
V2 0 b 1
Q1 0 b 0 qmod
.model dmod d(is=1e-14)
.model qmod npn(is=1e-16)
.options gmin=1e-3
.op
.end
