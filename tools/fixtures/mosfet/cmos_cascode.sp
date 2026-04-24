* NMOS Cascode Amplifier
* Two stacked NMOS (common-source + common-gate), resistor load

VDD vdd 0 DC 3.3
VIN in 0 DC 0 AC 1

* Input coupling
CC1 in gate1 1u

* Bias for input transistor gate (common-source)
RB1 vdd gate1 150k
RB2 gate1 0 100k

* Bias for cascode transistor gate (common-gate)
VCASC vcasc 0 DC 2.0

* Drain load resistor
RD vdd drain2 5k

* Common-source transistor M1
M1 drain1 gate1 0 0 NMOD W=50u L=1u

* Cascode transistor M2 (common-gate)
M2 drain2 vcasc drain1 0 NMOD W=50u L=1u

* Output coupling and load
CC2 drain2 out 1u
RL out 0 100k

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.AC DEC 20 10 1G

.END
