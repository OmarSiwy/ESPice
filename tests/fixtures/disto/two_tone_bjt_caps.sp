* Two-tone intermodulation of a BJT common emitter with junction and diffusion charge
* Expected results: two_tone_bjt_caps.expected.json
Vcc vcc 0 DC 12
Vin in 0 DC 0.7 AC 1 DISTOF1 0.01 DISTOF2 0.01
Rb in b 10k
Rc vcc c 4.7k
Q1 c b 0 qn
.model qn NPN(bf=120 is=1e-15 vaf=50 cje=1p cjc=0.5p tf=0.3n)
.disto dec 3 100k 100meg 0.9
.end
