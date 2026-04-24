* Inverting Amplifier (E Source Opamp Model)
*
* Gain = -Rf/R1 = -100k/10k = -10
* Opamp modeled as high-gain VCVS (E source)
*

V1 in 0 DC 0 AC 1
R1 in inv 10k
R2 inv out 100k
E1 out 0 0 inv 100k

.AC DEC 20 1 100MEG
.OP

.END
