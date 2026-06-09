* Autonomous HB (.hbosc) finds a Van der Pol LC oscillator's frequency
* Expected results: lc_oscillator.expected.json
L1 t 0 25.330296u
C1 t 0 1n
R1 t 0 10k
Bneg t 0 I=-7e-4*V(t)+8e-4*V(t)*V(t)*V(t)
.hbosc v(t) 1meg 7
.end
