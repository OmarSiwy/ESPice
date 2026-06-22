* Two-tone intermodulation through a diode with junction and diffusion charge and a phased F2
* Expected results: two_tone_diode_cap.expected.json
Vin in 0 DC .7 DISTOF1 0.01 DISTOF2 0.005 30
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14 cjo=10p vj=0.7 m=0.5 tt=1n)
.disto dec 3 100k 1g 0.9
.end
