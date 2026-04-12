* 3-Opamp Instrumentation Amplifier
*
* First two opamps (E1, E2) in non-inverting config with shared gain resistor Rg
* Third opamp (E3) as difference amplifier
* Overall gain = (1 + 2*R1/Rg) * (R3/R2)
* With R1=10k, Rg=1k, R2=R3=10k: Gain = (1 + 20) * 1 = 21
*

* Differential input signals
VPLUS inp 0 DC 0 AC 1
VMINUS inn 0 DC 0

* --- Stage 1: Non-inverting buffer/gain (Opamp A1) ---
* A1: non-inverting on inp
* Feedback: R1a from output to inverting node, Rg/2 to midpoint
R1A out1 n1a 10k
RGA n1a mid 500
E1 out1 0 inp n1a 100k

* --- Stage 1: Non-inverting buffer/gain (Opamp A2) ---
* A2: non-inverting on inn
* Feedback: R1b from output to inverting node, Rg/2 to midpoint
R1B out2 n2a 10k
RGB n2a mid 500
E2 out2 0 inn n2a 100k

* --- Stage 2: Difference amplifier (Opamp A3) ---
* Inputs from out1 and out2
R2A out1 n3inv 10k
R3A n3inv out 10k
R2B out2 n3nin 10k
R3B n3nin 0 10k
E3 out 0 n3nin n3inv 100k

* Output load
RLOAD out 0 100k

.AC DEC 20 1 100MEG

.END
