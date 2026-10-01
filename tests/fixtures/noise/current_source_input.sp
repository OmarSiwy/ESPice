* .noise referred to a current-source input (ngspice noisean.c accepts ISRC)
* Expected results: current_source_input.expected.json
* Oracle (analytic): R1's thermal noise at 300.15 K; the transfer from Iin to
* v(out) is R1, so onoise = sqrt(4kTR) and inoise = sqrt(4kT/R).
Iin 0 out DC 0 AC 1
R1 out 0 1000
.noise v(out) Iin dec 1 10 1k
.end
