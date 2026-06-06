* HSPICE defaults TNOM to 25 degC and runs the circuit at TNOM [SA Ch.20];
* ngspice's 27 degC gave a different junction voltage. Oracle: ngspice 45
* with .options tnom=25 temp=25.
* Expected results: tnom_default.expected.json
i1 0 a 1m
d1 a 0 dmod
.model dmod d is=1e-14 n=1.2 rs=5 eg=1.11 xti=3
.op
.end
