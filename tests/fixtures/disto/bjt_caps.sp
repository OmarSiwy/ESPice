* BJT common emitter with junction and diffusion charge: HD2/HD3 from the charge Taylor terms
* Expected results: bjt_caps.expected.json
Vcc vcc 0 DC 12
Vin in 0 DC 0.7 AC 1 DISTOF1 0.01
Rb in b 10k
Rc vcc c 4.7k
Q1 c b 0 qn
.model qn NPN(bf=120 is=1e-15 cje=1p cjc=0.5p tf=0.3n)
.disto dec 5 10k 100meg
.end
