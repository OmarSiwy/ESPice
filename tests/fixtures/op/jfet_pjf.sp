* A PJF model runs P-channel (#75): the card's polarity reaches jfet.va's
* jtype. Oracle: ngspice-45 on this deck (print all).
VD d 0 -1
VG g 0 0.5
J1 d g 0 pj
.model pj pjf vto=-2 beta=1e-4 lambda=0.01
.op
.end
