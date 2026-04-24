* Common-Base Amplifier
*
* VCC=12V, Q1 with base AC-grounded via bypass cap
* Current input at emitter, voltage output at collector
* Good high-frequency performance
*

VCC vcc 0 DC 12
VIN in 0 DC 0 AC 1

* Base bias
RB1 vcc base 47k
RB2 base 0 10k

* Base AC ground (bypass capacitor)
CB base 0 10u

* Emitter input with coupling and source resistance
RIN in n1 50
CIN n1 emit 1u
RE emit 0 2.2k

* Collector load
RC vcc col 4.7k

* Output coupling
COUT col out 1u
RL out 0 10k

* NPN in common-base configuration
Q1 col base emit NPN1

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.AC DEC 20 10 1G

.END
