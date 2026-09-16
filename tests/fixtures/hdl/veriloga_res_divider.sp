* Verilog-A resistor divider: va_res (100 ohm) under R1 -> v(out) = 0.35
* Expected results: veriloga_res_divider.expected.json
* Origin: benchmark/fixtures/verilogA/res_divider/circuit.sp
.hdl "veriloga_res_divider.assets/va_res.va"
N1 out 0 va_res
R1 in out 100
Vin in 0 DC 0.7
.op
.end
