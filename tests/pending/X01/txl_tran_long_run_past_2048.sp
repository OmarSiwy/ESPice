* X01 pending fixture: TXL run whose LIVE history depth exceeds the native
* 2048-entry capacity.  docs/native-transmission-line-migration.md records
* "CAP=2048 front pruning can discard a still-live point" for txl_native.
*   Td = length*sqrt(L*C) = 1 m * 5 ns/m = 5 ns, forced dt = 1 ps (tmax = 1 ps),
*   so the far end needs a sample 5000 entries back, 2952 beyond the bound.
* Z0 = sqrt(250n/100p) = 50 ohm, Rs = RL = Z0, GammaS = GammaL = 0, so the exact
* answer is a pure 5 ns delay of the matched divider:
*   v(a)(t) = 0.5 for t > 6 ns + 10 ps, 0 before
*   v(b)(t) = v(a)(t - 5 ns) = 0.5 for t > 11 ns + 10 ps, 0 before
* Hand-derived samples (accepted index = t/1 ps):
*   t =  3.0 ns  index  3000  v(a) = 0    v(b) = 0
*   t =  8.0 ns  index  8000  v(a) = 0.5  v(b) = 0
*   t = 10.9 ns  index 10900  v(a) = 0.5  v(b) = 0    (100 ps before arrival)
*   t = 12.0 ns  index 12000  v(a) = 0.5  v(b) = 0.5
*   t = 12.9 ns  index 12900  v(a) = 0.5  v(b) = 0.5
* The t = 10.9 ns sample is the gate.  Measured against the checkpoint binary this
* deck already fails there: the host publishes the edge at 8.0585 ns, which is
* 6 ns + 2048*1 ps, exactly the front-pruning horizon, while ngspice-44.2 publishes
* it at 11.0055 ns.  The identical circuit run at tmax = 10 ps (1301 accepted
* points, under the bound) puts the edge at 11.012 ns on both, so the defect is
* the capacity, not the model fit.
* Independent ngspice-44.2 agreement at the sampled times: <= 4.0e-12.
* Expected results: txl_tran_long_run_past_2048.expected.json
Vin in 0 PULSE(0 1 6n 10p 10p 500n 1u)
Rs in a 50
Y1 a 0 b 0 ymod
RL b 0 50
.model ymod txl R=1e-6 L=250n G=0 C=100p length=1
.tran 1p 13n 0 1p
.end
