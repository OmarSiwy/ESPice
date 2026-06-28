* HSPICE .measure PHASENOISE [CR .MEASURE] over phasenoise/lc_oscillator:
* L(fm) = kT/(R C^2 A^2 (2 pi fm)^2), -159.789 dBc/Hz at 10 kHz.
* Oracle: analytic, lc_oscillator's derivation.
* Expected results: meas_phasenoise.expected.json
L1 t 0 25.330296u
C1 t 0 1n
R1 t 0 10k
Bneg t 0 I=-7e-4*V(t)+8e-4*V(t)*V(t)*V(t)
.hbosc v(t) 1meg 7
.phasenoise v(t) dec 2 1k 1meg
.measure phasenoise l10k find phnoise at=10k
.end
