* A V source an F card senses keeps its AC drive (#103, #106).
* Expected results: sensed_vsource_ac.expected.json
* v(1) = V1 across R1; F1 mirrors 2 i(V1) out of node 2, so v(2) = 2 V1.
V1 1 0 DC 0 AC 1
R1 1 0 1k
F1 2 0 V1 2
R2 2 0 1k
.ac dec 1 1k 100k
.end
