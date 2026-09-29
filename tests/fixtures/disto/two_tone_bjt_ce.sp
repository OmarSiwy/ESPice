* Two-tone intermodulation of a BJT common emitter with the Early effect
* Expected results: two_tone_bjt_ce.expected.json
Vcc vcc 0 DC 12
Vin in 0 DC 0.7 AC 1 DISTOF1 0.01 DISTOF2 0.01
Rb in b 10k
Rc vcc c 4.7k
Q1 c b 0 qn
.model qn NPN(bf=120 is=1e-15 vaf=50)
.disto dec 3 1k 1meg 0.95
.end
