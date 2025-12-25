* Common-emitter amplifier, AC small-signal gain sweep.
VCC vcc 0 DC 12
Vin in 0 DC 0 AC 1
RB1 vcc base 47k
RB2 base 0 10k
RC vcc col 2.2k
RE emit 0 470
Cin in base 10u
Q1 col base emit QN
.model QN NPN(IS=1e-15 BF=180 VAF=80)
.ac dec 10 10 1meg
.end
