* #197: a Verilog-A module using the value of an unregistered $systf is refused by name (UnregisteredSystf), not given an invented value
* Expected results: veriloga_systf_value_refused.expected.json
.hdl "veriloga_systf.assets/va_systf_value.va"
N1 out 0 va_systf_value
R1 in out 1k
Vin in 0 DC 1
.op
.end
