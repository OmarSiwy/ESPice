* Shunt voltage regulator: series resistor with diode clamp to a bias rail.
Vsupply sup 0 DC 12
Rseries sup out 220
Dz out ref DZ
Vref ref 0 DC 5.1
Rload out 0 1k
.model DZ D(IS=1e-12 N=1)
.dc Vsupply 6 18 0.5
.end
