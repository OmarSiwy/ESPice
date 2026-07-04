* Golden disto: diode clipper.
Vin in 0 DC 0.6 AC 1 DISTOF1 0.1
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.disto dec 5 1k 10k
.end
