* HSPICE's default TNOM=25 reaches R tc1/tc2 (#146)
* Expected results: resistor_default_tnom.expected.json
V1 a 0 1
R1 a 0 1k tc1=0.01
.temp 125
.op
.end
