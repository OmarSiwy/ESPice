* Node a is read by B1's expression and connected to nothing (#92), so its
* KCL row is empty and no analysis has a unique solution. Every analysis
* must refuse it the same way. Oracle: ngspice 45 stops with "singular
* matrix: check node a".
* Expected results: floating_sense_node_op.expected.json
V1 in 0 sin(0 1 1k) ac 1
R1 in out 1k
B1 o2 0 V={v(a)+1}
R2 o2 0 1k
.op
.end
