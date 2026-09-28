* Verilog-A idt with ic: op at ic, AC transfer 1/(jw)
* Expected results: veriloga_idt_ac.expected.json
.hdl "veriloga_idt_ac.assets/va_idt.va"
Vin in 0 DC 0 AC 1
N1 in out va_idt
R1 out 0 1k
.op
.ac dec 1 1 1k
.end
