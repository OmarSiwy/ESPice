* Verilog inverter: input high -> output driven low
* Expected results: verilog_inverter.expected.json
* Origin: benchmark/fixtures/verilog/inverter/circuit.sp
.hdl "verilog_inverter.assets/v_inv.v"
Vin a 0 DC 5
Rl y 0 10k
N1 a y v_inv
.op
.end
