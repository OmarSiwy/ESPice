* All-source DC transfer past an F element: Vs is sensed, so it stamps
* nothing and is not a source of the transfer.
* Expected results: sensed_source.expected.json
V1 in 0 1
Vs in a 0
R1 a 0 1k
F1 0 out Vs 2
R2 out 0 1k
I1 0 out 1m
.dcxf v(out)
.end
