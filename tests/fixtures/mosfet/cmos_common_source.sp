* Common-Source NMOS Amplifier with AC Analysis
* Resistor drain load, bypassed source resistor, DC bias via resistive divider

VDD vdd 0 DC 3.3
VIN in 0 DC 0 AC 1

* Input coupling capacitor
CC1 in gate 1u

* Bias resistive divider
R1 vdd gate 100k
R2 gate 0 47k

* Drain load resistor
RD vdd drain 5k

* Source resistor with bypass capacitor
RS source 0 1k
CS source 0 10u

* NMOS amplifier
M1 drain gate source 0 NMOD W=50u L=1u

* Output coupling capacitor and load
CC2 drain out 1u
RL out 0 100k

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.AC DEC 20 10 1G

.END
