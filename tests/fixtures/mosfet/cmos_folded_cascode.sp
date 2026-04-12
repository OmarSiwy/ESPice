* Folded Cascode CMOS Opamp
* PMOS input pair folded into NMOS cascode + PMOS cascode mirrors
* ~12 transistors for full symmetrical OTA

VDD vdd 0 DC 3.3
VSS vss 0 DC 0

* Input: DC bias + AC stimulus
VPLUS inp 0 DC 1.65 AC 1
VMINUS inn 0 DC 1.65

* Bias voltages
VBNCASC vbncasc 0 DC 1.0
VBNCS vbncs 0 DC 0.8
VBPCASC vbpcasc 0 DC 2.3
VBPCS vbpcs 0 DC 2.5

*** PMOS Input Differential Pair ***
* PMOS tail current source
M11 ptail vbpcs vdd vdd PMOD W=80u L=2u

* PMOS input pair
M1 net1 inp ptail vdd PMOD W=40u L=1u
M2 net2 inn ptail vdd PMOD W=40u L=1u

*** NMOS Cascode Current Mirrors (bottom) ***
* NMOS current sources
M5 nets1 vbncs 0 0 NMOD W=20u L=2u
M6 nets2 vbncs 0 0 NMOD W=20u L=2u

* NMOS cascode devices
M7 net1 vbncasc nets1 0 NMOD W=20u L=1u
M8 net2 vbncasc nets2 0 NMOD W=20u L=1u

*** PMOS Cascode Current Mirrors (top) ***
* PMOS current sources
M9 netp1 vbpcs vdd vdd PMOD W=40u L=2u
M10 netp2 vbpcs vdd vdd PMOD W=40u L=2u

* PMOS cascode devices
M3 net1 vbpcasc netp1 vdd PMOD W=40u L=1u
M4 out vbpcasc netp2 vdd PMOD W=40u L=1u

* Output NMOS cascode (forms output branch with M4)
M12 out vbncasc nets2 0 NMOD W=20u L=1u

* Output load
CL out 0 5p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.AC DEC 20 1 1G

.END
