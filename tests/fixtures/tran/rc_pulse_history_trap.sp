* Repeated rise/fall edges retain capacitor history
* Expected results: rc_pulse_history_trap.expected.json
Vin in 0 PULSE(0 1 1m .1m .1m 1m 3m)
R1 in out 1k
C1 out 0 1u
.tran 1u 6m 0 1u
.options method=trap reltol=1e-6
.end
