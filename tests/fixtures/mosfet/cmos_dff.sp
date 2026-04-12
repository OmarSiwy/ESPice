* D Flip-Flop (Master-Slave using Transmission Gates)
* Master latch captures D on CLK falling edge
* Slave latch outputs Q on CLK rising edge
* ~20 transistors total

VDD vdd 0 DC 3.3

* Clock and Data inputs
VCLK clk 0 PULSE(0 3.3 5n 0.5n 0.5n 10n 20n)
VDATA d 0 PULSE(0 3.3 2n 0.5n 0.5n 15n 40n)

*** Clock inverter -> clkbar ***
M1 clkbar clk vdd vdd PMOD W=10u L=1u
M2 clkbar clk 0 0 NMOD W=5u L=1u

*** MASTER LATCH ***

* TG1: Transmission gate passes D when CLK=0 (clkbar=1)
* NMOS controlled by clkbar, PMOS controlled by clk
MTG1N d clkbar mi 0 NMOD W=5u L=1u
MTG1P d clk mi vdd PMOD W=10u L=1u

* Master inverter: mi -> mout
M3 mout mi vdd vdd PMOD W=10u L=1u
M4 mout mi 0 0 NMOD W=5u L=1u

* Master feedback inverter: mout -> mfb
M5 mfb mout vdd vdd PMOD W=5u L=1u
M6 mfb mout 0 0 NMOD W=2.5u L=1u

* TG2: Feedback TG passes mfb to mi when CLK=1 (holds master)
* NMOS controlled by clk, PMOS controlled by clkbar
MTG2N mfb clk mi 0 NMOD W=2.5u L=1u
MTG2P mfb clkbar mi vdd PMOD W=5u L=1u

*** SLAVE LATCH ***

* TG3: Transmission gate passes mout when CLK=1
* NMOS controlled by clk, PMOS controlled by clkbar
MTG3N mout clk si 0 NMOD W=5u L=1u
MTG3P mout clkbar si vdd PMOD W=10u L=1u

* Slave inverter: si -> q
M7 q si vdd vdd PMOD W=10u L=1u
M8 q si 0 0 NMOD W=5u L=1u

* Slave feedback inverter: q -> sfb
M9 sfb q vdd vdd PMOD W=5u L=1u
M10 sfb q 0 0 NMOD W=2.5u L=1u

* TG4: Feedback TG passes sfb to si when CLK=0 (holds slave)
* NMOS controlled by clkbar, PMOS controlled by clk
MTG4N sfb clkbar si 0 NMOD W=2.5u L=1u
MTG4P sfb clk si vdd PMOD W=5u L=1u

* Load capacitances
CQ q 0 0.1p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.TRAN 0.1n 100n

.END
