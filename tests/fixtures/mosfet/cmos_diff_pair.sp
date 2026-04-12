* NMOS Differential Pair with PMOS Active Load
* M1/M2 input pair, M3/M4 PMOS current mirror load, M5 tail current source

VDD vdd 0 DC 3.3

* DC bias + AC stimulus on positive input
VPLUS inp 0 DC 1.65 AC 1
* DC bias on negative input
VMINUS inn 0 DC 1.65

* PMOS active load (current mirror)
* M3: diode-connected
M3 drain1 drain1 vdd vdd PMOD W=20u L=2u
* M4: mirror output
M4 out drain1 vdd vdd PMOD W=20u L=2u

* NMOS differential input pair
M1 drain1 inp tail 0 NMOD W=10u L=1u
M2 out inn tail 0 NMOD W=10u L=1u

* Tail current source (NMOS biased by VBIAS)
VBIAS biasg 0 DC 0.9
M5 tail biasg 0 0 NMOD W=20u L=2u

* Load capacitance at output
CL out 0 0.5p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.AC DEC 20 100 1G
.DC VPLUS 1.0 2.3 0.01

.END
