* 1 V across 1e-10 and 1e-12 Ohm (#152): i(v1) = -1e10 A, i(v2) = -1e12 A.
* Currents past 1e9 A are this circuit's scale, not a runaway, so the
* operating point solves rather than publishing zeros with exit 0.
* Oracle: analytic (Ohm's law); ngspice 45 gives the same.
* Expected results: tiny_resistors.expected.json
V1 a 0 1
R1 a 0 1e-10
V2 b 0 1
R2 b 0 1e-12
.op
.end
