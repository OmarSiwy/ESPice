* Delayed finite-rise RC step
* Expected results: finite_rise_positive.expected.json
Vin in 0 PULSE(0 1 1m .1m .1m 20m 50m)
R1 in out 1k
C1 out 0 1u
.tran 1u 8m 0 1u
.options reltol=1e-6
.end
