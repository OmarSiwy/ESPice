* 4-Stage Dickson Charge Pump
*
* Uses diodes in series with clock-driven coupling capacitors
* VDD=3.3V, target output ~15V (4*VDD - 4*Vd ~ 4*3.3 - 4*0.7 = 10.4V ideal,
*   but with clock amplitude = VDD, actual ~ VDD + 4*(VDD-Vd) ~ 13.7V)
* Two complementary clock phases: phi1 and phi2
* C_stage=10pF, C_load=10pF

.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* Power supply
VDD vdd 0 DC 3.3

* Two-phase non-overlapping clocks at 100MHz (period=10ns)
V_PHI1 phi1 0 PULSE(0 3.3 0 0.1n 0.1n 4.9n 10n)
V_PHI2 phi2 0 PULSE(0 3.3 5n 0.1n 0.1n 4.9n 10n)

* Stage 0: input diode
D0 vdd s1 DMOD

* Stage 1: coupling cap on phi1
C1 s1 phi1 10p
D1 s1 s2 DMOD

* Stage 2: coupling cap on phi2
C2 s2 phi2 10p
D2 s2 s3 DMOD

* Stage 3: coupling cap on phi1
C3 s3 phi1 10p
D3 s3 s4 DMOD

* Stage 4: coupling cap on phi2
C4 s4 phi2 10p
D4 s4 out DMOD

* Output storage cap and load
C_out out 0 10p
R_load out 0 100k

.TRAN 0.1n 500n

.END
