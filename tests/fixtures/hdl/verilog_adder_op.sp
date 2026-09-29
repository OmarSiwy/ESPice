* Verilog full adder settling in the operating point: a = b = 1, cin = 0
* gives s = 2'b10, which the device drives only after its static pass reads
* the inputs (it is born with every net x)
* Expected results: verilog_adder_op.expected.json
* Oracle (analytic): vdd = 3.3 V, so vth = 1.65 V; a and b read 1, cin 0.
* s[1] drives 3.3 V through rout = 1 ohm into 10 kohm:
* 3.3 * 10000/10001 = 3.29967003 V; s[0] drives 0 V. Pins run in port
* order with vectors left to right: a b cin s[1] s[0].
.hdl "verilog_adder_op.assets/v_add.v"
Va a 0 DC 3.3
Vb b 0 DC 3.3
Vc c 0 DC 0
N1 a b c s1 s0 addm
.model addm v_add vdd=3.3
R1 s1 0 10k
R0 s0 0 10k
.op
.end
