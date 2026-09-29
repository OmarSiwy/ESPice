* HSPICE .op t1 t2 [CR .OP]: an operating point at each transient time.
* Oracle: analytic RC step response from 0 V, v(out) = 1 - exp(-t / 5 ns):
* 0.18127 at 1 ns and 0.63212 at 5 ns.
* Expected results: op_times.expected.json
v1 in 0 pulse(0 1 0 1p 1p 1 2)
r1 in out 1k
c1 out 0 5p
.tran 0.1n 10n
.op 1n 5n
.end
