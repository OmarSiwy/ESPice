* NMOS Source Follower (Common Drain) Amplifier
* NMOS with large resistor load for current source approximation

VDD vdd 0 DC 3.3
VIN in 0 DC 0 AC 1

* Input coupling capacitor
CC1 in gate 1u

* Gate bias via resistive divider
R1 vdd gate 100k
R2 gate 0 100k

* NMOS source follower: drain to VDD, output at source
M1 vdd gate source 0 NMOD W=50u L=1u

* Current source load (large resistor approximation)
RSS source 0 10k

* Output coupling and load
CC2 source out 1u
RL out 0 100k

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.AC DEC 20 10 1G

.END
