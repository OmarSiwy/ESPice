* EXP's omitted delays and time constants come from TSTEP (#73).
* Expected results: source_exp_defaults_ngspice.expected.json
* TD1 = TAU1 = TAU2 = 1n, TD2 = 2n: a rise from 1 ns, a fall from 2 ns.
V1 a 0 EXP(0 1)
R1 a 0 1k
.tran 1n 20n
.end
