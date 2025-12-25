* DISTO fixture: BJT common-emitter distortion.
Vcc vcc 0 DC 12
Vin in 0 DC 0.7 AC 1 DISTOF1 0.01
Rb in b 10k
Rc vcc c 4.7k
Q1 c b 0 qn
.model qn NPN(bf=120 is=1e-15)
.disto dec 10 1k 1meg
.end
