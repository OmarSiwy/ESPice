* NPN Common-Emitter Amplifier with Voltage Divider Bias
*
* VCC=12V, voltage divider bias (R1=56k, R2=10k)
* RC=4.7k, RE=1k with bypass cap CE=10u
* CIN=1u coupling, COUT=1u coupling
*

VCC vcc 0 DC 12
VIN in 0 DC 0 AC 1

* Input coupling
CIN in base 1u

* Voltage divider bias
R1 vcc base 56k
R2 base 0 10k

* Collector and emitter resistors
RC vcc col 4.7k
RE emit 0 1k

* Emitter bypass capacitor
CE emit 0 10u

* Output coupling
COUT col out 1u

* Load resistor
RL out 0 10k

* BJT
Q1 col base emit NPN1

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.AC DEC 20 10 100MEG

.END
