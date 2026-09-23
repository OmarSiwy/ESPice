* Explicit 0 PULSE edges, width and period take the .tran defaults (#73).
* Expected results: source_pulse_zero_edges_ngspice.expected.json
* ngspice vsrcload.c: TR = TF = TSTEP = 10n, PW = PER = TSTOP = 1u, so v(a)
* ramps 0 -> 1 over the first 10 ns and stays at 1.
V1 a 0 PULSE(0 1 0 0 0 0 0)
R1 a 0 1k
.tran 10n 1u
.end
