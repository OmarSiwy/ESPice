* Verilog-A idt with ic under uic: the integral starts from ic
* Expected results: veriloga_idt_uic.expected.json
.hdl "veriloga_idt_ac.assets/va_idt.va"
Vin in 0 DC 1
N1 in out va_idt
R1 out 0 1k
.tran 0.1 1 uic
.end
