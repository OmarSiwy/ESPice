* Sideband truncation must be integral.
* Expected results: pnoise_fractional_sidebands.expected.json
Vin in 0 1
R1 in out 1k
R2 out 0 1k
.pnoise v(out) Vin dec 4 10 100 1k 1.5
.end
