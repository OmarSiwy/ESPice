* Common-emitter BJT amplifier, DC operating point
Vcc vcc 0 5
Vin in  0 0.7
Rb in b 100k
Rc vcc c 1k
Re e 0  100
Q1 c b e QNPN
.model QNPN NPN(IS=1e-15 BF=100 VAF=50)
.op
.end
