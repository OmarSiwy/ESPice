* NPN BJT in active region: Gummel-Poon DC operating point.
VCC c 0 DC 5
VBB b 0 DC 0.7
RC c col 1k
RB b base 10k
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=100)
.op
.end
