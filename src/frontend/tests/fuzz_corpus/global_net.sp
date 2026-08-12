* .global makes vdd one net at every subcircuit level; ignoring it gave the
* subcircuit its own x1.vdd and v(out) = 0. Oracle: ngspice 45.
* Expected results: global_net.expected.json
.global vdd
vdd vdd 0 1
.subckt load a
r1 a vdd 1k
.ends
x1 out load
r2 out 0 1k
.op
.end
