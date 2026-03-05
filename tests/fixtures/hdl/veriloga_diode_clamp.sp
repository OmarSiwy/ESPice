* Verilog-A diode clamp: va_diode under 1k -> v(out) ~ 0.57 V
* Expected results: veriloga_diode_clamp.expected.json
* Origin: benchmark/fixtures/verilogA/diode_clamp/circuit.sp
.hdl "veriloga_diode_clamp.assets/va_diode.va"
Vin in 0 DC 5
R1 in out 1k
N1 out 0 va_diode
.op
.end
