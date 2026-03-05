* Resistor thermal noise and exact white-noise integration
* Expected results: unequal_temp_minus40.expected.json
Vin in 0 DC 0 AC 1
R1 in out 1000
R2 out 0 3000
.noise v(out) Vin dec 4 10 10k
.options temp=-40 tnom=27
.end
