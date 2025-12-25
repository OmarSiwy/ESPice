* Unit fixture: coupled transmission lines (CPL), two-conductor crosstalk.
Vin in1 0 DC 0 PULSE(0 1 1n 0.5n 0.5n 5n 20n)
Rs1 in1 a1 50
Rs2 a2 0 50
P1 a1 a2 0 b1 b2 0 pline
RL1 b1 0 50
RL2 b2 0 50
.model pline CPL R=0.2 0 0.2 L=9.13n 3.3n 9.13n G=0 0 0 C=0.365p -0.09p 0.365p length=10
.tran 0.05n 30n
.end
