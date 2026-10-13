* KNOWN GAP: VerA's contract.Systf does not say whether a $systf call is a task, so ESPice refuses a task-position call too (UnregisteredSystf) instead of running it as a no-op (#197)
* A Verilog-A resistor that calls an unregistered $systf as a task: the call changes nothing, so v(out) = 0.5 V
* Expected results: veriloga_systf_task.expected.json
.hdl "veriloga_systf_task.assets/va_systf_task.va"
N1 out 0 va_systf_task
R1 in out 1k
Vin in 0 DC 1
.op
.end
