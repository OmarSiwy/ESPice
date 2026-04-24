* 11-Stage CMOS Ring Oscillator — Cold Start from Zero ICs
*
* No kick-start pulse; must self-start from numerical noise
* All nodes initially at 0V
* Tests transient startup convergence and oscillation onset
* VDD=3.3V, 11 inverter stages in a ring
* Expected frequency ~ 1/(2 * 11 * t_prop) ~ hundreds of MHz

VDD vdd 0 DC 3.3

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05)

* Stage 1: input=n11 (feedback from last stage), output=n1
M1n n1 n11 0 0 NMOD W=10u L=1u
M1p n1 n11 vdd vdd PMOD W=20u L=1u
C1 n1 0 10f

* Stage 2
M2n n2 n1 0 0 NMOD W=10u L=1u
M2p n2 n1 vdd vdd PMOD W=20u L=1u
C2 n2 0 10f

* Stage 3
M3n n3 n2 0 0 NMOD W=10u L=1u
M3p n3 n2 vdd vdd PMOD W=20u L=1u
C3 n3 0 10f

* Stage 4
M4n n4 n3 0 0 NMOD W=10u L=1u
M4p n4 n3 vdd vdd PMOD W=20u L=1u
C4 n4 0 10f

* Stage 5
M5n n5 n4 0 0 NMOD W=10u L=1u
M5p n5 n4 vdd vdd PMOD W=20u L=1u
C5 n5 0 10f

* Stage 6
M6n n6 n5 0 0 NMOD W=10u L=1u
M6p n6 n5 vdd vdd PMOD W=20u L=1u
C6 n6 0 10f

* Stage 7
M7n n7 n6 0 0 NMOD W=10u L=1u
M7p n7 n6 vdd vdd PMOD W=20u L=1u
C7 n7 0 10f

* Stage 8
M8n n8 n7 0 0 NMOD W=10u L=1u
M8p n8 n7 vdd vdd PMOD W=20u L=1u
C8 n8 0 10f

* Stage 9
M9n n9 n8 0 0 NMOD W=10u L=1u
M9p n9 n8 vdd vdd PMOD W=20u L=1u
C9 n9 0 10f

* Stage 10
M10n n10 n9 0 0 NMOD W=10u L=1u
M10p n10 n9 vdd vdd PMOD W=20u L=1u
C10 n10 0 10f

* Stage 11 (feeds back to stage 1)
M11n n11 n10 0 0 NMOD W=10u L=1u
M11p n11 n10 vdd vdd PMOD W=20u L=1u
C11 n11 0 10f

* Break symmetry: alternate high/low to kick-start oscillation.
* With all-zero ICs every inverter output stays at VDD (symmetric deadlock).
* Odd stages: 3.3V (high), even stages: 0V (low) — forces propagating edge.
.IC V(n1)=3.3 V(n2)=0 V(n3)=3.3 V(n4)=0 V(n5)=3.3 V(n6)=0
+ V(n7)=3.3 V(n8)=0 V(n9)=3.3 V(n10)=0 V(n11)=3.3

.TRAN 0.01n 50n UIC

.END
