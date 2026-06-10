* All-source DC transfer to a differential and a branch-current output
* Expected results: resistive_bridge.expected.json
V1 in 0 1
R1 in a 1k
R2 a 0 3k
R3 in b 2k
R4 b 0 2k
I1 0 a 1m
.dcxf v(a,b)
.dcxf v(a,b) tf
.dcxf i(V1) tf
.end
