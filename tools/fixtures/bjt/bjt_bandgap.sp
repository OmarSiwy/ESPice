* Bandgap Voltage Reference
*
* Q1 (1x) and Q2 (8x via IS scaling) create delta-VBE across R2
* R1 sets PTAT current, Q3 sums VBE + PTAT voltage
* Target output ~1.25V
*

VCC vcc 0 DC 5

* PNP current mirror to supply equal currents to both branches
Q5 col1 col1 vcc PNP1
Q6 col2 col1 vcc PNP1
Q7 col3 col1 vcc PNP1

* Branch 1: Q1 (1x) with R1
* Diode-connected Q1
R1A col1 base1 10k
Q1 base1 base1 0 NPN1

* Branch 2: Q2 (8x, IS=8e-15) with R2 in emitter
R1B col2 base2 10k
Q2 base2 base2 emit2 NPN8X
R2 emit2 0 1.2k

* Branch 3: Q3 output stage sums VBE + PTAT
R3 col3 vout 7.5k
Q3 vout vout 0 NPN1

* Output load
RLOAD vout 0 100k

* Standard NPN (1x)
.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

* 8x NPN (IS scaled by 8)
.MODEL NPN8X NPN (BF=100 IS=8e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

* PNP for current mirror
.MODEL PNP1 PNP (BF=80 IS=1e-15 VAF=80 RB=15 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.5n TR=8n)

.OP
.DC TEMP -40 125 5

.END
