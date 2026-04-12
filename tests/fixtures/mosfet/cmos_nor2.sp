* 2-Input CMOS NOR Gate Transient
* Two parallel NMOS, two series PMOS

VDD vdd 0 DC 3.3
VA a 0 PULSE(0 3.3 5n 0.5n 0.5n 15n 40n)
VB b 0 PULSE(0 3.3 10n 0.5n 0.5n 10n 20n)

* Series PMOS pull-up network
M3 mid a vdd vdd PMOD W=20u L=1u
M4 out b mid vdd PMOD W=20u L=1u

* Parallel NMOS pull-down network
M1 out a 0 0 NMOD W=10u L=1u
M2 out b 0 0 NMOD W=10u L=1u

* Load capacitance
CL out 0 0.1p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.TRAN 0.1n 80n

.END
