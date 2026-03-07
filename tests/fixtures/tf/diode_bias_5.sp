* Linearize the nonlinear diode at the solved bias
* Expected results: diode_bias_5.expected.json
Vin in 0 5
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.tf v(out) Vin
.options reltol=1e-7 abstol=1e-14 vntol=1e-9
.end
