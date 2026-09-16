* RC circuit excited by a pulse train (VACASK benchmark)
* Expected results: vacask_rc.expected.json
* Origin: benchmark/fixtures/vacask/rc/circuit.sp
* ~1M timesteps, linear circuit, stress-tests per-iteration overhead

vs 1 0 dc 0 pulse 0 1 1u 1u 1u 1m 2m
r1 1 2 1k
c1 2 0 1u

.options klu

.tran 1u 1 0 1u

.end
