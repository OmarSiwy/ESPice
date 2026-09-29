* Two-tone intermodulation through a diode with a linear shunt capacitor and a phased F2
* Expected results: two_tone_diode_rc.expected.json
Vin in 0 DC .7 DISTOF1 0.01 DISTOF2 0.005 30
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
C1 out 0 1n
.disto dec 2 10k 10meg 0.9
.end
