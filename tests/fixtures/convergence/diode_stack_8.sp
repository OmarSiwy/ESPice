* 8 series junctions
* Expected results: diode_stack_8.expected.json
Vin in 0 20
R1 in n1 1k
D1 n1 n2 dm
D2 n2 n3 dm
D3 n3 n4 dm
D4 n4 n5 dm
D5 n5 n6 dm
D6 n6 n7 dm
D7 n7 n8 dm
D8 n8 0 dm
.model dm D(is=1e-14)
.op
.end
