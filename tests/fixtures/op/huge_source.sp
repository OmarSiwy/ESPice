* A 1e12 V source into 1 kOhm (#152): v(a) = 1e12 V, i(v1) = -1e9 A.
* The converger's runaway bound scales with the circuit's own drive, so the
* exact solve is accepted instead of refused and published as zeros.
* Oracle: analytic (Ohm's law); ngspice 45 gives the same.
* Expected results: huge_source.expected.json
V1 a 0 1e12
R1 a 0 1k
.op
.end
