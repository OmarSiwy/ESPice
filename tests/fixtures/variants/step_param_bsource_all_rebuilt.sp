* .step param where no point is the nominal value and a B source reads the
* parameter: every point rebuilds as its own run and the main run keeps no
* query. Its job table used to be sized 0 and written anyway (#132).
* Oracle: analytic, v(out) = g * v(a) = g.
* Expected results: step_param_bsource_all_rebuilt.expected.json
.param g=1
v1 a 0 1
bout out 0 v=g*v(a)
rload out 0 1k
.step param g list 2 3
.op
.end
