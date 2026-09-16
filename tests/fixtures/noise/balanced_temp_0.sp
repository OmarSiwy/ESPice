* Resistor thermal noise and exact white-noise integration
* Expected results: balanced_temp_0.expected.json
Vin in 0 DC 0 AC 1
R1 in out 1000
R2 out 0 1000
.noise v(out) Vin dec 4 10 10k
.options temp=0 tnom=27
.end
