* CMOS Inverter Transient Switching
* Pulse input, observe output with load capacitance

VDD vdd 0 DC 3.3
VIN in 0 PULSE(0 3.3 1n 0.5n 0.5n 10n 20n)

* PMOS: source=VDD, gate=in, drain=out, bulk=VDD
M2 out in vdd vdd PMOD W=20u L=1u

* NMOS: drain=out, gate=in, source=0, bulk=0
M1 out in 0 0 NMOD W=10u L=1u

* Load capacitance
CL out 0 0.1p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.TRAN 0.1n 50n

.END
