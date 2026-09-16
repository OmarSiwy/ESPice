* AC Jacobian and capacitance around a nonlinear bias point
* Expected results: diode_linearization_5.expected.json
Vin in 0 DC 5 AC 1
R1 in out 1k
D1 out 0 dm
C1 out 0 1u
.model dm D(is=1e-14)
.ac dec 4 10 10k
.options reltol=1e-7 abstol=1e-14 vntol=1e-9
.end
