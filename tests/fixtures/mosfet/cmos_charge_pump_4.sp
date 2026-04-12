* 4-Stage Dickson Charge Pump
* 4 diode-connected NMOS stages pumped by complementary clocks
* Output voltage should approach ~5*VDD - 5*VTH theoretically

VDD vdd 0 DC 3.3
VIN in 0 DC 3.3

* Complementary clock signals
VCLK1 clk1 0 PULSE(0 3.3 0 0.5n 0.5n 5n 10n)
VCLK2 clk2 0 PULSE(3.3 0 0 0.5n 0.5n 5n 10n)

* Stage 1: diode-connected NMOS + pump capacitor
M1 n1 n1 in 0 NMOD W=20u L=1u
C1 n1 clk1 2p

* Stage 2: diode-connected NMOS + pump capacitor
M2 n2 n2 n1 0 NMOD W=20u L=1u
C2 n2 clk2 2p

* Stage 3: diode-connected NMOS + pump capacitor
M3 n3 n3 n2 0 NMOD W=20u L=1u
C3 n3 clk1 2p

* Stage 4: diode-connected NMOS + pump capacitor
M4 n4 n4 n3 0 NMOD W=20u L=1u
C4 n4 clk2 2p

* Output filter capacitor and load
COUT out 0 10p
RL out 0 1MEG

* Output diode-connected NMOS
M5 out out n4 0 NMOD W=20u L=1u

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.TRAN 0.1n 200n

.END
