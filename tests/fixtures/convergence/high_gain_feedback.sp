* High Open-Loop Gain Amplifier — Newton Convergence Challenge
*
* VCVS with gain=1e6 in inverting configuration
* Extremely high gain stresses Newton-Raphson convergence
* Tests both DC operating point and AC frequency response

V1 in 0 DC 0 AC 1
R1 in inv 1k
R2 inv out 1MEG
E1 out 0 0 inv 1e6

.OP
.AC DEC 20 1 100MEG

.END
