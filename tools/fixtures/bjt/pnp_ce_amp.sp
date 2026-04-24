* PNP Common-Emitter Amplifier with Inverted Supply
*
* VCC=-12V (inverted supply for PNP)
* Voltage divider bias (R1=56k, R2=10k)
* RC=4.7k, RE=1k with bypass cap CE=10u
*

VEE vee 0 DC -12
VIN in 0 DC 0 AC 1

* Input coupling
CIN in base 1u

* Voltage divider bias (referenced to VEE)
R1 vee base 56k
R2 base 0 10k

* Collector and emitter resistors
RC vee col 4.7k
RE emit 0 1k

* Emitter bypass capacitor
CE emit 0 10u

* Output coupling
COUT col out 1u

* Load resistor
RL out 0 10k

* PNP BJT
Q1 col base emit PNP1

.MODEL PNP1 PNP (BF=80 IS=1e-15 VAF=80 RB=15 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.5n TR=8n)

.OP
.AC DEC 20 10 100MEG

.END
