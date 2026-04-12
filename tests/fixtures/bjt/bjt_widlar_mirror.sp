* Widlar Current Mirror (with Emitter Resistor)
*
* Q1 + Q2 mirror, Q2 has RE2=1k for current scaling
* IREF=1mA, output current is lower due to RE2
*

VCC vcc 0 DC 12

* Reference current source
IREF vcc col1 DC 1m

* Diode-connected Q1 (reference side)
Q1 col1 col1 0 NPN1

* Mirror transistor Q2 with emitter degeneration
Q2 col2 col1 emit2 NPN1
RE2 emit2 0 1k

* Load resistor on Q2 collector
RLOAD vcc col2 10k

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP

.END
