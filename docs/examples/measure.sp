Measurements on an RC step response
* RC = 1 us. The input steps 0 -> 1 V at 1 us and back at 6 us.
V1 in 0 PULSE(0 1 1u 1n 1n 5u 20u)
R1 in out 1k
C1 out 0 1n
.tran 10n 10u
.meas tran trise TRIG v(out) VAL=0.1 RISE=1 TARG v(out) VAL=0.9 RISE=1
.meas tran tdelay TRIG v(in) VAL=0.5 RISE=1 TARG v(out) VAL=0.5 RISE=1
.meas tran vat3u FIND v(out) AT=3u
.meas tran tcross WHEN v(out)=0.5 FALL=1
.meas tran vmax MAX v(out)
.meas tran vavg AVG v(out) FROM=0 TO=10u
.meas tran vrms RMS v(out) FROM=0 TO=10u
.meas tran slope DERIV v(out) AT=2u
.meas tran charge INTEG i(V1) FROM=1u TO=6u
.meas tran ratio PARAM='trise/tdelay'
.end
