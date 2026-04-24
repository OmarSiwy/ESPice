* BJT Differential Pair with Resistor Loads
*
* VCC=12V, Q1/Q2 NPN differential pair
* Tail current source IEE=1mA
* RC1=RC2=4.7k collector loads
*

VCC vcc 0 DC 12
VPLUS inp 0 DC 6.0 AC 1
VMINUS inn 0 DC 6.0

* Collector load resistors
RC1 vcc col1 4.7k
RC2 vcc col2 4.7k

* Differential pair transistors
Q1 col1 inp tail NPN1
Q2 col2 inn tail NPN1

* Tail current source
IEE tail 0 DC 1m

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.AC DEC 20 10 100MEG
.DC VPLUS 5.5 6.5 0.01

.END
