* AC fixture: three independent sources driven AT ONCE, each at its own
* magnitude and phase, one V card undriven. ngspice CKTacLoad loads every
* source into the same rhs; a single-branch unit poke cannot express this.
V1 a 0 DC 0 AC 1
V2 b 0 DC 0 AC 2 90
V3 d 0 DC 0
I1 0 c AC 0.5 -45
R1 a 0 1k
R2 b 0 1k
R3 c 0 1k
R4 d 0 1k
.ac dec 2 1k 10k
.end
