* 21-Stage CMOS Ring Oscillator
* 21 inverters in a ring; output fed back to input
* Kick-start via initial condition on first node

VDD vdd 0 DC 3.3

* Stage 1
M1P n1 n21 vdd vdd PMOD W=20u L=1u
M1N n1 n21 0 0 NMOD W=10u L=1u
C1 n1 0 10f

* Stage 2
M2P n2 n1 vdd vdd PMOD W=20u L=1u
M2N n2 n1 0 0 NMOD W=10u L=1u
C2 n2 0 10f

* Stage 3
M3P n3 n2 vdd vdd PMOD W=20u L=1u
M3N n3 n2 0 0 NMOD W=10u L=1u
C3 n3 0 10f

* Stage 4
M4P n4 n3 vdd vdd PMOD W=20u L=1u
M4N n4 n3 0 0 NMOD W=10u L=1u
C4 n4 0 10f

* Stage 5
M5P n5 n4 vdd vdd PMOD W=20u L=1u
M5N n5 n4 0 0 NMOD W=10u L=1u
C5 n5 0 10f

* Stage 6
M6P n6 n5 vdd vdd PMOD W=20u L=1u
M6N n6 n5 0 0 NMOD W=10u L=1u
C6 n6 0 10f

* Stage 7
M7P n7 n6 vdd vdd PMOD W=20u L=1u
M7N n7 n6 0 0 NMOD W=10u L=1u
C7 n7 0 10f

* Stage 8
M8P n8 n7 vdd vdd PMOD W=20u L=1u
M8N n8 n7 0 0 NMOD W=10u L=1u
C8 n8 0 10f

* Stage 9
M9P n9 n8 vdd vdd PMOD W=20u L=1u
M9N n9 n8 0 0 NMOD W=10u L=1u
C9 n9 0 10f

* Stage 10
M10P n10 n9 vdd vdd PMOD W=20u L=1u
M10N n10 n9 0 0 NMOD W=10u L=1u
C10 n10 0 10f

* Stage 11
M11P n11 n10 vdd vdd PMOD W=20u L=1u
M11N n11 n10 0 0 NMOD W=10u L=1u
C11 n11 0 10f

* Stage 12
M12P n12 n11 vdd vdd PMOD W=20u L=1u
M12N n12 n11 0 0 NMOD W=10u L=1u
C12 n12 0 10f

* Stage 13
M13P n13 n12 vdd vdd PMOD W=20u L=1u
M13N n13 n12 0 0 NMOD W=10u L=1u
C13 n13 0 10f

* Stage 14
M14P n14 n13 vdd vdd PMOD W=20u L=1u
M14N n14 n13 0 0 NMOD W=10u L=1u
C14 n14 0 10f

* Stage 15
M15P n15 n14 vdd vdd PMOD W=20u L=1u
M15N n15 n14 0 0 NMOD W=10u L=1u
C15 n15 0 10f

* Stage 16
M16P n16 n15 vdd vdd PMOD W=20u L=1u
M16N n16 n15 0 0 NMOD W=10u L=1u
C16 n16 0 10f

* Stage 17
M17P n17 n16 vdd vdd PMOD W=20u L=1u
M17N n17 n16 0 0 NMOD W=10u L=1u
C17 n17 0 10f

* Stage 18
M18P n18 n17 vdd vdd PMOD W=20u L=1u
M18N n18 n17 0 0 NMOD W=10u L=1u
C18 n18 0 10f

* Stage 19
M19P n19 n18 vdd vdd PMOD W=20u L=1u
M19N n19 n18 0 0 NMOD W=10u L=1u
C19 n19 0 10f

* Stage 20
M20P n20 n19 vdd vdd PMOD W=20u L=1u
M20N n20 n19 0 0 NMOD W=10u L=1u
C20 n20 0 10f

* Stage 21 (output feeds back to stage 1 input)
M21P n21 n20 vdd vdd PMOD W=20u L=1u
M21N n21 n20 0 0 NMOD W=10u L=1u
C21 n21 0 10f

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

* Kick-start: asymmetric initial condition to break metastability
.IC V(n1)=3.3

.TRAN 0.01n 50n UIC

.END
