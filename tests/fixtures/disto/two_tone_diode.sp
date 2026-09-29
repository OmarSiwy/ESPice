* Two-tone Volterra intermodulation of a resistor-diode divider
* Expected results: two_tone_diode.expected.json
Vin in 0 DC .7 DISTOF1 0.01 DISTOF2 0.01
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.disto dec 1 100 10k 0.9
.end
