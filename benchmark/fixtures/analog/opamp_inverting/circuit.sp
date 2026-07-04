* Inverting amplifier built from a VCVS ideal op-amp (gain -Rf/Rin = -10).
Vin in 0 DC 0.1
Rin in n1 1k
Rf n1 out 10k
* High-gain VCVS: out = A*(v+ - v-), v+ = gnd, v- = n1
Eopamp out 0 0 n1 1e6
.op
.end
