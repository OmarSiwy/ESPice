* NMOS Current Mirror
* IREF into diode-connected M1, M2 mirrors current into load resistor

VDD vdd 0 DC 3.3
IREF vdd drain1 DC 100u

* Diode-connected NMOS (gate tied to drain)
M1 drain1 drain1 0 0 NMOD W=10u L=2u

* Mirror transistor
M2 drain2 drain1 0 0 NMOD W=10u L=2u

* Load resistor on M2 drain
RL vdd drain2 10k

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.OP
.DC IREF 10u 500u 10u

.END
