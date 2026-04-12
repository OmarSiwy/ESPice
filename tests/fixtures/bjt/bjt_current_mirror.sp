* Simple NPN Current Mirror
*
* IREF=1mA via diode-connected Q1
* Q2 mirrors current to load resistor
*

VCC vcc 0 DC 12

* Reference current source
IREF vcc col1 DC 1m

* Diode-connected Q1 (collector tied to base)
Q1 col1 col1 0 NPN1

* Mirror transistor Q2
Q2 col2 col1 0 NPN1

* Load resistor on Q2 collector
RLOAD vcc col2 5k

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.DC IREF 0.1m 5m 0.1m

.END
