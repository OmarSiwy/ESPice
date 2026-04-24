* Wilson Current Mirror (3 Transistors)
*
* Q1 diode-connected, Q2 output, Q3 feedback
* Higher output impedance than simple mirror
*

VCC vcc 0 DC 12

* Reference current
IREF vcc col1 DC 1m

* Q1: diode-connected (sets reference)
Q1 col1 col1 emit3 NPN1

* Q3: feedback transistor
Q3 emit3 col2 0 NPN1

* Q2: output transistor
Q2 col2 col1 0 NPN1

* Sweep voltage source on output
VCE vcc col2s DC 5
ROUT col2s col2 0.001

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.DC VCE 0 10 0.01

.END
