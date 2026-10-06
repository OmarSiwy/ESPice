The four controlled sources and a B source
V1 in 0 DC 2
R1 in 0 1k
* VCVS: v(e) = 3 * v(in)
E1 e 0 in 0 3
RE e 0 1k
* VCCS: 1 mA/V from in, pushed into node g
G1 0 g in 0 1m
RG g 0 1k
* Current through Vsense sets F (CCCS) and H (CCVS)
Vsense in sense DC 0
RS sense 0 2k
F1 0 f Vsense 2
RF f 0 1k
H1 h 0 Vsense 500
RH h 0 1k
* Behavioural source: any expression of node voltages
B1 b 0 V={v(in)*v(in)/4}
RB b 0 1k
.op
.end
