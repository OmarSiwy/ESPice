* JFET amplifier small-signal transfer
* Expected results: jfet_common_source_ac.expected.json
Vdd vdd 0 10
Vin gate 0 DC -1 AC 1
Rd vdd out 2k
J1 out gate 0 jm
.model jm NJF(vto=-2 beta=1m lambda=.01 cgs=5p cgd=2p)
.ac dec 5 10 100meg
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
