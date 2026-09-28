* HSPICE .tran tstep1 tstop1 tstep2 tstop2 runs to the last tstop [CR
* .TRAN]; the ngspice reading stopped at 10 ns and hid the output before
* 1 ns. Oracle: analytic RC step response, 1 - exp(-t / 5 ns).
* Expected results: tran_segments.expected.json
v1 in 0 pulse(0 1 0 1p 1p 1 2)
r1 in out 1k
c1 out 0 5p
.tran 0.1n 10n 1n 40n
.end
