* HSPICE .measure event forms [CR .MEASURE]: a TARG inheriting TRIG's TD,
* TD=TRIG, FROM/TO naming earlier results, par() waveforms, CROSS=LAST,
* TRAN_CONT and EM_AVG. Oracle: analytic, v(s) = sin(2 pi 1MEG t) crosses
* 0.5 rising at 1/12, 13/12, 25/12 us and falling at 5/12, 17/12, 29/12 us;
* its peak between them is 1; sin^2 averages 1/2 over a period, 2 sin has
* RMS sqrt 2, and EM_AVG over a period is (1 - 0.5) / pi.
* Expected results: meas_events.expected.json
.option delmax=2n em_recovery=0.5
v1 s 0 sin(0 1 1meg)
r1 s 0 1k
.tran 1n 3u
.measure tran d1 trig v(s) val=0.5 td=1u rise=1 targ v(s) val=0.5 fall=1
.measure tran d2 trig v(s) val=0.5 rise=2 targ v(s) val=0.5 fall=1 td=trig
.measure tran tl when v(s)=0.5 cross=last
.measure tran ta when v(s)=0.5 rise=1
.measure tran tb when v(s)=0.5 fall=1
.measure tran pk max v(s) from=ta to=tb
.measure tran sq avg par('v(s)*v(s)') from=0 to=1u
.measure tran r2 rms par('2*v(s)') from=1u to=2u
.measure tran_cont tc when v(s)=0.5 rise=1
.measure tran em em_avg v(s) from=0 to=1u
.end
