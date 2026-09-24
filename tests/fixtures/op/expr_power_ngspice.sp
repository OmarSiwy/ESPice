* .param powers of a negative base follow ngspice's numparam: |x|^y (#39, #77).
* Expected results: expr_power_ngspice.expected.json
* b = -1.75: b^2.5 = 4.0513, b^3 = +5.359, pwr(b,3) = +5.359, (-8)**(1/3) = 2.
.param b=-1.75
V1 a 0 {b^2.5}
R1 a 0 1
V2 c 0 {b^3}
R2 c 0 1
V3 d 0 {pwr(b,3)}
R3 d 0 1
V4 e 0 {(-8)**(1/3)}
R4 e 0 1
.op
.end
