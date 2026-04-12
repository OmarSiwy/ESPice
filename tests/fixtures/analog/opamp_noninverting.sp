* Non-Inverting Amplifier (E Source Opamp Model)
*
* Gain = 1 + Rf/R1 = 1 + 100k/10k = 11
* Opamp modeled as high-gain VCVS (E source)
*

V1 inp 0 DC 0 AC 1
R1 inv 0 10k
R2 inv out 100k
E1 out 0 inp inv 100k

.AC DEC 20 1 100MEG
.OP

.END
