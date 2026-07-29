Resistor divider noise
* Two 10k resistors: the output noise is that of 5k, about 9.1 nV/sqrt(Hz).
V1 in 0 DC 0 AC 1
R1 in out 10k
R2 out 0 10k
.noise v(out) V1 dec 1 1k 100k
.end
