* HSPICE's W element is a lossy line (RLGC model), not ngspice's current
* switch: rejected in the HSPICE dialect until it is built. Oracle: input
* contract (HSPICE only).
* Expected results: w_element.expected.json
v1 in 0 1
w1 in 0 out 0 rlgcmodel=m n=1 l=0.1
r1 out 0 50
.op
.end
