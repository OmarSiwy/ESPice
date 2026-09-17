* A D card on an NPN model is refused, as ngspice-45's "incorrect model
* type" (#75), not run as a diode of default parameters.
V1 a 0 1
D1 a 0 qm
.model qm npn
.op
.end
