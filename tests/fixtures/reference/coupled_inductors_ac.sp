* Mutual inductance magnitude, orientation and leakage
* Expected results: coupled_inductors_ac.expected.json
Vin in 0 AC 1
Rs in a 10
L1 a 0 1m
L2 out 0 4m
K1 L1 L2 .9
Rl out 0 100
.ac dec 5 10 1meg
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
