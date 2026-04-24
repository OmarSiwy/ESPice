* SR Latch from Cross-Coupled CMOS NOR Gates
* NOR1 inputs: S, Qbar -> output Q
* NOR2 inputs: R, Q -> output Qbar

VDD vdd 0 DC 3.3

* S and R inputs (staggered pulses)
VS s 0 PULSE(0 3.3 5n 0.5n 0.5n 10n 60n)
VR r 0 PULSE(0 3.3 30n 0.5n 0.5n 10n 60n)

*** NOR Gate 1: inputs S, Qbar -> output Q ***
* Series PMOS
M1P mid1 s vdd vdd PMOD W=20u L=1u
M2P q qbar mid1 vdd PMOD W=20u L=1u
* Parallel NMOS
M1N q s 0 0 NMOD W=10u L=1u
M2N q qbar 0 0 NMOD W=10u L=1u

*** NOR Gate 2: inputs R, Q -> output Qbar ***
* Series PMOS
M3P mid2 r vdd vdd PMOD W=20u L=1u
M4P qbar q mid2 vdd PMOD W=20u L=1u
* Parallel NMOS
M3N qbar r 0 0 NMOD W=10u L=1u
M4N qbar q 0 0 NMOD W=10u L=1u

* Load capacitances
CQ q 0 0.1p
CQBAR qbar 0 0.1p

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.IC V(q)=0 V(qbar)=3.3

.TRAN 0.1n 100n UIC

.END
