* Miller-Compensated Two-Stage CMOS Opamp
* Stage 1: NMOS diff pair (M1/M2) + PMOS mirror load (M3/M4) + tail source (M5)
* Stage 2: Common-source M6 + PMOS active load M7
* Miller compensation: Cc + Rz between stage 1 output and stage 2 output

VDD vdd 0 DC 3.3
VSS vss 0 DC 0

* Input: DC bias + AC stimulus
VPLUS inp 0 DC 1.65 AC 1
VMINUS inn 0 DC 1.65

*** STAGE 1: Differential Pair with PMOS Active Load ***

* PMOS current mirror load
M3 net1 net1 vdd vdd PMOD W=40u L=2u
M4 net2 net1 vdd vdd PMOD W=40u L=2u

* NMOS differential pair
M1 net1 inp tail 0 NMOD W=20u L=1u
M2 net2 inn tail 0 NMOD W=20u L=1u

* NMOS tail current source
VBIAS1 nbias 0 DC 0.8
M5 tail nbias 0 0 NMOD W=40u L=2u

*** STAGE 2: Common-Source with Active Load ***

* PMOS active load
VBIAS2 pbias 0 DC 2.5
M7 out pbias vdd vdd PMOD W=80u L=1u

* NMOS common-source gain stage
M6 out net2 0 0 NMOD W=80u L=1u

*** Miller Compensation ***
* Series Rz for RHP zero cancellation
RZ net2 netcc 2k
CC netcc out 2p

* Output load
CL out 0 5p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.AC DEC 20 1 1G

.END
