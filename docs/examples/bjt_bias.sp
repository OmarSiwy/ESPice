BJT bias point and output curves
VCC vcc 0 5
VB b 0 DC 0.7
Q1 c b 0 qnpn
RC vcc c 1k
.model qnpn NPN(IS=1e-15 BF=150 VAF=80)
.op
.dc VCC 0 5 0.05 VB 0.65 0.75 0.05
.end
