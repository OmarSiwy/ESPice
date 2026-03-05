* Volterra diode second harmonic and amplitude scaling
* Expected results: diode_0p01.expected.json
Vin in 0 DC .7 DISTOF1 0.01
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.disto dec 3 100 10k
.end
