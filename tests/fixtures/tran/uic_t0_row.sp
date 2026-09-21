* .tran UIC (#161): no operating point runs, so the t = 0 row must still
* satisfy KVL with C1 held at its initial 0 V: v(a) = 2, v(b) = 0,
* i(v1) = -2 mA. Then v(b) = 2 (1 - exp(-t/RC)), RC = 1 us.
* Oracle: analytic; ngspice 45 prints no t = 0 row under UIC and its first
* row (t = 0.1 ns) reads v(a) = 2, i(v1) = -1.9998 mA.
* Expected results: uic_t0_row.expected.json
V1 a 0 2
R1 a b 1k
C1 b 0 1n
.tran 10n 3u UIC
.end
