* Nonlinear periodic orbit validated by settled transient
* Expected results: diode_clipper.expected.json
Vin in 0 SIN(0 1 1k)
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
C1 out 0 10n
.pss 1k 512
.end
