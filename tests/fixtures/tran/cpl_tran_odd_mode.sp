* X01 pending fixture: CPL two-conductor ODD mode, matched to Zo.
* Identical matrices to cpl_tran_even_mode (Ze = 100, Zo = 25, Td = 8 ns for both
* modes), but the conductors are driven differentially through 25 ohm sources and
* terminated in 25 ohm, which excites and matches the odd mode alone:
*   v(a1) = +1 * Zo/(Rs+Zo) = +0.5,  v(a2) = -0.5   for t > 10 ps
*   v(b1) = +0.5 and v(b2) = -0.5, both delayed by Td = 8 ns
* Hand-derived samples:
*   t =  4.0 ns  v(a1)=+0.5 v(a2)=-0.5  v(b1)= 0    v(b2)= 0
*   t =  7.9 ns  v(a1)=+0.5 v(a2)=-0.5  v(b1)= 0    v(b2)= 0
*   t =  8.2 ns  v(a1)=+0.5 v(a2)=-0.5  v(b1)=+0.5  v(b2)=-0.5
*   t = 20.0 ns  v(a1)=+0.5 v(a2)=-0.5  v(b1)=+0.5  v(b2)=-0.5
*   t = 39.0 ns  v(a1)=+0.5 v(a2)=-0.5  v(b1)=+0.5  v(b2)=-0.5  (DC 25/50 = 0.5)
* Together with cpl_tran_even_mode this pins both eigenvalues of the 2x2 L and C
* matrices from flat plateaus: a model that produces one impedance for both modes
* (Ze = Zo) cannot satisfy both fixtures, since 100 ohm and 25 ohm terminations
* are simultaneously matched only if Ze = 100 and Zo = 25.
* Independent ngspice-44.2 agreement: <= 1.5e-9.
* Expected results: cpl_tran_odd_mode.expected.json
Vs1 in1 0 PULSE(0 1 0 10p 10p 500n 1u)
Vs2 in2 0 PULSE(0 -1 0 10p 10p 500n 1u)
Rs1 in1 a1 25
Rs2 in2 a2 25
P1 a1 a2 0 b1 b2 0 cmod
RL1 b1 0 25
RL2 b2 0 25
.model cmod CPL
+R = 1e-6 0 1e-6
+L = 250n 150n
+     250n
+C = 100p -60p
+     100p
+G = 0 0 0
+length = 2
.tran 20p 40n 0 20p
.end
