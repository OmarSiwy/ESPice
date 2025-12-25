* Promote fixture: tiny nonlinear cell solved ~1000x (MC intent) — the
* promotion planner's first-run-never-compiles / cache-hit target.
Vin in 0 DC 3
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14 n=1.5)
.op
.end
