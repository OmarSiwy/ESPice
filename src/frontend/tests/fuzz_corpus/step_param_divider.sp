* .step param over a resistor divider: one operating point per point,
* each plot named after its point. rv also reaches r3 through the derived
* parameter rhalf. Oracle: analytic, v(b) = rp/(1k + rp), rp = rv || rv/2.
* Expected results: step_param_divider.expected.json
.param rv=1k rhalf='rv/2'
v1 a 0 1
r1 a b 1k
r2 b 0 {rv}
r3 b 0 {rhalf}
.step param rv list 1k 3k 6k
.op
.end
