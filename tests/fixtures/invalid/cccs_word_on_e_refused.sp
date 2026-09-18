* A controlled-source type word for another letter is refused (#75):
* ngspice-45 fails 'E1 o 0 CCCS Vs 2'; it is not a zero-gain VCVS.
V1 a 0 1
Vs a b 0
R1 b 0 1k
E1 o 0 CCCS Vs 2
R2 o 0 1k
.op
.end
