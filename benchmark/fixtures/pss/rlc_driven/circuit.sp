* PSS fixture: driven series RLC settles to periodic steady state.
Vin in 0 DC 0 SIN(0 1 10k)
R1 in n1 50
L1 n1 out 1m
C1 out 0 100n
* Card is ESPice's documented form (freq samples), not ngspice's
* gfreq/tstab/oscnob/harms card: tstab and oscnob have no Options equivalent.
.pss 10k 256
.end
