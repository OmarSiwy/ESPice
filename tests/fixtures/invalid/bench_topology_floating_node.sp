* Topology fixture: node `island` has no DC path to ground (cap-coupled
* Expected results: bench_topology_floating_node.expected.json
* Origin: benchmark/fixtures/topology/floating_node/circuit.sp
* island). Golden = the engine's named floating-node error.
V1 in 0 DC 5
C1 in island 1n
C2 island 0 1n
R1 in 0 1k
.op
.end
