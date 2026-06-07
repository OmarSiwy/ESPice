* The capacitor-only node fl makes the operating point a 1 us transient
* (OPtran), long enough for the timer to fire three times. None of that may
* reach the analysis: the transient starts at t = 0 with the timer unfired.
* Expected results: veriloga_optran_timer.expected.json
.hdl "veriloga_timer_rearm.assets/va_tick.va"
N1 out va_tick per=0.3u
R1 out 0 1k
C1 fl 0 1p
C2 fl out 1p
.tran 0.1u 1.2u
.end
