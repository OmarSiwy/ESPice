* A consistent current cutset (#70): I1 drives 1 mA into a node that only
* C1 and I2 (1 mA out) touch. KCL balances for any v(a), so the circuit is
* valid; the transient operating point keeps v(a) at its start, 0 V, and
* R1 carries I2: v(b) = 1 V. Oracle: analytic; ngspice 45 .op gives a = 0,
* b = 1 through its transient operating point.
* Expected results: equal_current_sources.expected.json
I1 0 a 1m
I2 a b 1m
R1 b 0 1k
C1 a 0 1p
.tran 1n 10n
.end
