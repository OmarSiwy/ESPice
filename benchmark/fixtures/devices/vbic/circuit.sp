* Unit fixture: VBIC NPN bias point (level 4).
Vcc vcc 0 DC 5
Vb b 0 DC 0.8
Rc vcc c 1k
Q1 c b 0 vb1
.model vb1 NPN(level=4)
.op
.end
