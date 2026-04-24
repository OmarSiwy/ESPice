* Common-Collector (Emitter Follower)
*
* VCC=12V, NPN with RE=1k
* Unity voltage gain, low output impedance
*

VCC vcc 0 DC 12
VIN in 0 DC 6 AC 1

* Input coupling capacitor
CIN in base 1u

* Base bias resistors
RB1 vcc base 47k
RB2 base 0 47k

* Emitter resistor (load)
RE emit 0 1k

* Output coupling
COUT emit out 1u
RL out 0 10k

* NPN emitter follower
Q1 vcc base emit NPN1

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.AC DEC 20 10 100MEG

.END
