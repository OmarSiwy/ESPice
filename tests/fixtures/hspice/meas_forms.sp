* HSPICE .measure spellings [CR .MEASURE]: an omitted analysis type (the
* last analysis card), INTEGRAL, DERIVATIVE, PARAM= over other results and
* the ERR family; all were dropped with a warning. Oracle: analytic, RC =
* 1 us charging to 1 V, and v(out2) = 0.9 v(out) for a 10 % error.
* Expected results: meas_forms.expected.json
v1 in 0 pulse(0 1 0 1p 1p 1 2)
r1 in out 1k
c1 out 0 1n
e2 out2 0 out 0 0.9
.tran 10n 5u
.measure t50 when v(out)=0.5
.measure tran area integral v(out) from=0 to=5u
.measure tran slope derivative v(out) at=1u
.measure tran twice param='t50*2'
.measure tran e1 err1 v(out) v(out2) from=1u to=5u
.measure tran e2 err2 v(out) v(out2)
.end
