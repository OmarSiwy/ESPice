* HSPICE W element, two coupled lossy conductors: the CPL crosstalk circuit of
* tran/device_coupled_tlines.sp with its P card rewritten as a W card (same
* per-unit-length R, L, C; HSPICE lists lower triangles).
* Expected results: w_coupled_cpl.expected.json
* Oracle: ngspice-44.2 running the original CPL deck (P card, cpl model).
Vin in1 0 DC 0 PULSE(0 1 1n 0.5n 0.5n 5n 20n)
Rs1 in1 a1 50
Rs2 a2 0 50
W1 a1 a2 0 b1 b2 0 rlgcmodel=pline n=2 l=10
RL1 b1 0 50
RL2 b2 0 50
.model pline w modeltype=rlgc n=2 ro=0.2 0 0.2 lo=9.13n 3.3n 9.13n co=0.365p -0.09p 0.365p
.tran 0.05n 30n
.end
