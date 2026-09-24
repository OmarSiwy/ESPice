* .four v(a,b) analyses the difference, not v(a) (#57).
* Expected results: differential_output.expected.json
* v(a) = 0.5 sin, v(b) = 0.25 sin in phase: v(a,b) = 0.25 sin, |H1| = 0.25
* (ngspice-45: 0.2499).
Va a 0 sin(0 0.5 1k)
Vb b 0 sin(0 0.25 1k)
Ra a 0 1k
Rb b 0 1k
.tran 1u 2m
.four 1k v(a,b)
.end
