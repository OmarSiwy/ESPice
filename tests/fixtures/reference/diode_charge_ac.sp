* Bias-dependent diode depletion and diffusion capacitance
* Expected results: diode_charge_ac.expected.json
Vin in 0 DC .7 AC 1
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14 cjo=10p tt=10n)
.ac dec 5 1k 1g
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
