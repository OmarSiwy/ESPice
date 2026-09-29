* A two-tone .disto needs a DISTOF2 source, as ngspice E_NOF2SRC.
* Expected results: disto_f2_without_source.expected.json
Vin in 0 DC .7 DISTOF1 0.01
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.disto dec 1 100 10k 0.9
.end
