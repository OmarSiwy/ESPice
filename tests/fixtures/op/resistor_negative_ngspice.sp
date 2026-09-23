* A negative resistance keeps its sign, and m= scales it, as in ngspice (#73).
* Expected results: resistor_negative_ngspice.expected.json
* ngspice-45 resparam.c/restemp.c: R1 = -2k gives i(v1) = +0.5 mA;
* R3 = 1k with m=-2 conducts -2 mS, i(v3) = +2 mA.
V1 a 0 1
R1 a 0 -2k
V3 c 0 1
R3 c 0 1k m=-2
.op
.end
