* Verilog-A $strobe: va_strobe (100 ohm) under R1 prints its 0.35 V drop at the operating point
* Expected results: veriloga_strobe.expected.json
.hdl "veriloga_strobe.assets/va_strobe.va"
N1 out 0 va_strobe
R1 in out 100
Vin in 0 DC 0.7
.op
.end
