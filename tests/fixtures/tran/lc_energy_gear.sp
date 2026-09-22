* Lossless LC phase and energy conservation
* Expected results: lc_energy_gear.expected.json
L1 out 0 1m
C1 out 0 1u
.ic v(out)=1
.tran 10n 1m 0 10n uic
.options method=gear reltol=1e-7
.end
