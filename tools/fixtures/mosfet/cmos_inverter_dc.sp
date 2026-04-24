* CMOS Inverter DC Transfer Curve (VTC)
* Sweep VIN 0 to 3.3V, observe VOUT

VDD vdd 0 DC 3.3
VIN in 0 DC 0

* PMOS: source=VDD, gate=in, drain=out, bulk=VDD
M2 out in vdd vdd PMOD W=20u L=1u

* NMOS: drain=out, gate=in, source=0, bulk=0
M1 out in 0 0 NMOD W=10u L=1u

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.DC VIN 0 3.3 0.01

.END
