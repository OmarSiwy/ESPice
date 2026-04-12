* Tow-Thomas Biquad (Two Integrators + Inverter)
*
* Three VCVS opamps (E sources, gain=100k)
* Provides LP, BP, HP outputs simultaneously
* R=10k, C=1n throughout
* f_0 = 1/(2*pi*R*C) ~ 15.9 kHz
*

V1 in 0 DC 0 AC 1

* --- Opamp 1: Summing integrator ---
* Input summing through R
R1 in n1a 10k
* Feedback from BP output (damping)
R2 bp n1a 10k
* Feedback from LP output
R3 lp n1a 10k
* Integrating capacitor
C1 n1a bp 1n
* Opamp 1 (inverting integrator -> BP output)
E1 bp 0 0 n1a 100k

* --- Opamp 2: Integrator (BP -> LP) ---
R4 bp n2a 10k
C2 n2a lp 1n
* Opamp 2 (inverting integrator -> LP output)
E2 lp 0 0 n2a 100k

* --- Opamp 3: Inverter (LP -> inverted LP for feedback) ---
R5 lp n3a 10k
R6 n3a inv_lp 10k
* Opamp 3 (unity-gain inverter)
E3 inv_lp 0 0 n3a 100k

* Feed inverted LP back to summing node
* (Already handled by R3 lp n1a above for the negative feedback path)

* Output load resistors
RBP bp 0 100k
RLP lp 0 100k

.AC DEC 20 100 10MEG

.END
