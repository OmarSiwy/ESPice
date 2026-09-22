* A V source an F card senses is a .dc sweep target (#103, #106).
* Expected results: sensed_vsource_dc_sweep.expected.json
* v(1) = V1 across R1; F1 mirrors 2 i(V1) out of node 2, so v(2) = 2 V1.
V1 1 0 DC 1
R1 1 0 1k
F1 2 0 V1 2
R2 2 0 1k
.dc V1 0 1 0.5
.end
