* Verilog-A resistor divider: va_res (100 ohm) under R1 -> v(out) = 0.35
.hdl "va_res.va"
N1 out 0 va_res
R1 in out 100
Vin in 0 DC 0.7
.op
.end
