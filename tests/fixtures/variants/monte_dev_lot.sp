* HSPICE LOT/DEV tolerances on a .model value: LOT draws once per model
* per trial, DEV once per device. Two diodes of one model at 1 mA each:
* each voltage sees both, their difference only DEV. A GAUSS value is
* the 3-sigma spread [SA Ch.20], so 30% and 6% are sigmas of 10% and 2%.
* Oracle: analytic, first order in the relative spread of IS:
* v = n Vt ln(I/IS), so sigma(v(a)) = Vt sqrt(0.1^2 + 0.02^2) = 2.64 mV and
* sigma(v(a) - v(b)) = Vt 0.02 sqrt(2) = 0.731 mV (Vt = 25.85 mV at 27 C).
* Expected results: monte_dev_lot.expected.json
i1 0 a 1m
i2 0 b 1m
d1 a 0 dmod
d2 b 0 dmod
e1 d 0 a b 1
.model dmod d is=1e-14 lot/gauss=30% dev/gauss=6%
.option seed=11
.dc monte=4000
.end
