* 2 series junctions
* Expected results: diode_stack_2.expected.json
Vin in 0 20
R1 in n1 1k
D1 n1 n2 dm
D2 n2 0 dm
.model dm D(is=1e-14)
.op
.end
