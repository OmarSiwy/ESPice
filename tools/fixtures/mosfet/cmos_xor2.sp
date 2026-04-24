* CMOS XOR Gate from Transmission Gates
* XOR = A'B + AB' using 2 inverters + 2 transmission gates

VDD vdd 0 DC 3.3
VA a 0 PULSE(0 3.3 5n 0.5n 0.5n 15n 40n)
VB b 0 PULSE(0 3.3 10n 0.5n 0.5n 10n 20n)

* Inverter for A -> abar
M1 abar a vdd vdd PMOD W=20u L=1u
M2 abar a 0 0 NMOD W=10u L=1u

* Inverter for B -> bbar
M3 bbar b vdd vdd PMOD W=20u L=1u
M4 bbar b 0 0 NMOD W=10u L=1u

* Transmission gate 1: passes B when A=1 (A high, Abar low)
* TG1: NMOS controlled by A, PMOS controlled by Abar
M5 b a out 0 NMOD W=10u L=1u
M6 b abar out vdd PMOD W=20u L=1u

* Transmission gate 2: passes Bbar when A=0 (Abar high, A low)
* TG2: NMOS controlled by Abar, PMOS controlled by A
M7 bbar abar out 0 NMOD W=10u L=1u
M8 bbar a out vdd PMOD W=20u L=1u

* Load capacitance
CL out 0 0.1p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.TRAN 0.1n 80n

.END
