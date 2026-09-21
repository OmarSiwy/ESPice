* .sens to BJT parameters left at their "infinite" default of 0 (#91):
* VAF, VAR, IKF and IKR read 0 (dV/dp tends to 0 as p tends to infinity),
* as in ngspice, instead of a finite-difference artefact whose sign followed
* line order. IS, ISC and the principal R/V columns are ordinary.
* Oracle: ngspice 45 (`ngspice -b`, `print all` in a .control block).
* Expected results: bjt_infinite_defaults.expected.json
VCC vcc 0 5
VB b 0 0.7
RC vcc c 1k
Q1 c b 0 qn
.model qn npn(is=1e-16 bf=100)
.sens v(c)
.end
