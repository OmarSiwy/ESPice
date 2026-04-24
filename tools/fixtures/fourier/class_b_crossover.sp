* Class-B Push-Pull Output Stage — Crossover Distortion
*
* VCC=15V, VEE=-15V
* NPN emitter follower (positive half) + PNP emitter follower (negative half)
* No bias: dead zone around zero crossing creates crossover distortion
* SIN input at 1kHz, 5V peak
* Fourier analysis reveals odd harmonics from crossover nonlinearity

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)
.MODEL PNP1 PNP (BF=80 IS=1e-15 VAF=80 RB=15 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.5n TR=8n)

VCC vcc 0 DC 15
VEE vee 0 DC -15

* Input signal: 1kHz sine, 5V peak
VIN in 0 SIN(0 5 1k)

* NPN emitter follower (sources current on positive half)
Q1 vcc in out NPN1

* PNP emitter follower (sinks current on negative half)
Q2 vee in out PNP1

* Load resistor
R_load out 0 100

.TRAN 10u 10m
.FOUR 1k V(out)

.END
