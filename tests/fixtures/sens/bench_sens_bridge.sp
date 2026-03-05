* SENS fixture: Wheatstone bridge tap sensitivity near balance.
* Expected results: bench_sens_bridge.expected.json
* Origin: benchmark/fixtures/sens/bridge/circuit.sp
Vin top 0 DC 10
R1 top a 1k
R2 a 0 1.01k
R3 top b 1k
R4 b 0 1k
R5 a b 10k
.sens V(a)
.end
