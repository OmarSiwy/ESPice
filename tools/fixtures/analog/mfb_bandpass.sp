* Multiple-Feedback Bandpass Filter
*
* Inverting opamp (VCVS model) with R/C feedback network
* Center frequency set by R1, R2, R3, C1, C2
*

V1 in 0 DC 0 AC 1
R1 in n1 10k
C1 n1 n2 1n
R2 n2 0 10k
C2 n1 out 1n
R3 n1 out 10k
E1 out 0 0 n2 100k

.AC DEC 20 100 10MEG

.END
