* Darlington Pair Emitter Follower
*
* Q1 drives Q2 base, Q2 emitter to load
* VCC=12V, RL=100 ohm
*

VCC vcc 0 DC 12
VIN in 0 DC 5

* Base resistor for Q1
RB in base1 1k

* Darlington pair
* Q1 collector to VCC, emitter drives Q2 base
Q1 vcc base1 base2 NPN1

* Q2 collector to VCC, emitter to load
Q2 vcc base2 emit2 NPN1

* Load resistor
RL emit2 0 100

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.DC VIN 0 10 0.1

.END
