* Cascode Amplifier (Two Stacked NPN)
*
* Q1 in common-emitter, Q2 in common-base on top
* VCC=12V, RC=4.7k
* Q2 base biased via voltage divider for cascode voltage
*

VCC vcc 0 DC 12
VIN in 0 DC 0 AC 1

* Input coupling
CIN in base1 1u

* Bias for Q1 (CE stage)
RB1 vcc base1 100k
RB2 base1 0 22k

* Emitter resistor for Q1
RE1 emit1 0 1k
CE1 emit1 0 10u

* Cascode bias for Q2 base (fixed voltage ~6V)
RD1 vcc base2 10k
RD2 base2 0 10k
CB2 base2 0 10u

* Collector load
RC vcc col2 4.7k

* Output coupling
COUT col2 out 1u
RL out 0 10k

* Q1: common-emitter stage
Q1 col1 base1 emit1 NPN1

* Q2: common-base stage (stacked on Q1)
Q2 col2 base2 col1 NPN1

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.OP
.AC DEC 20 10 1G

.END
