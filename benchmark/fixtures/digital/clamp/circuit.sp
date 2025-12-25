* Diode clamp on a logic line: limits overshoot to one diode drop above rail.
Vin in 0 DC 0 PULSE(0 6 0 1n 1n 20n 40n)
R1 in node 200
D1 node vdd DCLP
Vdd vdd 0 DC 3.3
C1 node 0 5p
.model DCLP D(IS=1e-14)
.tran 0.5n 80n
.end
