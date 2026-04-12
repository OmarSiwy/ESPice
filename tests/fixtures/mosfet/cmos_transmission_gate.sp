* CMOS Transmission Gate Pass/Block
* NMOS + PMOS in parallel, control signal toggles pass/block

VDD vdd 0 DC 3.3
VIN in 0 SIN(1.65 1.0 100MEG)
VCTRL ctrl 0 PULSE(0 3.3 10n 0.5n 0.5n 15n 30n)

* Inverter for complementary control
M3 ctrlbar ctrl vdd vdd PMOD W=20u L=1u
M4 ctrlbar ctrl 0 0 NMOD W=10u L=1u

* Transmission gate: NMOS gate=ctrl, PMOS gate=ctrlbar
M1 in ctrl out 0 NMOD W=10u L=1u
M2 in ctrlbar out vdd PMOD W=20u L=1u

* Load
CL out 0 0.1p
RL out 0 100k

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.TRAN 0.1n 50n

.END
