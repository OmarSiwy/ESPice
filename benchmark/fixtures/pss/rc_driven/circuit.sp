* PSS bench fixture: sine-driven RC, shooting lands on the periodic state.
Vin in 0 DC 0 SIN(0 2 1k)
R1 in out 1k
C1 out 0 1u
* Card is ESPice's documented form (freq samples), not ngspice's
* gfreq/tstab/oscnob/harms card: tstab and oscnob have no Options equivalent.
.pss 1k 256
.end
