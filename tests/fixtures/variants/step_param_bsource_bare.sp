* .step param over a .param a B-source expression reads as a bare name
* (not in braces). The name folds into the B tape's constant pool, so every
* point rebuilds its own circuit; that rebuild used to recurse until the
* stack overflowed. Oracle: analytic, v(out) = g * v(a) = g.
* Expected results: step_param_bsource_bare.expected.json
.param g=1
v1 a 0 1
bout out 0 v=g*v(a)
rload out 0 1k
.step param g list 1 2
.op
.end
