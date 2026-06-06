* Verilog-A timer whose start time the event itself re-arms: each fire
* toggles a level and schedules the next fire one period later, and
* transition slews V(out) over tr from each fire time
* Expected results: veriloga_timer_rearm.expected.json
.hdl "veriloga_timer_rearm.assets/va_tick.va"
N1 out va_tick
R1 out 0 1k
.tran 0.37u 5u
.end
