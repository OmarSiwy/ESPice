* Input source sees only a 1e-30 S path: Rin clamps to 1e20 as in ngspice
* Expected results: tiny_input_conductance.expected.json
V1 in 0 1
R1 in 0 1e30
E1 out 0 in 0 2
R2 out 0 1k
.tf v(out) V1
.end
