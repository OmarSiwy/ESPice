* Opamp Differentiator (C at Input)
*
* Transfer function: Vout/Vin = -s*R1*C1
* C1=1n, R1=10k -> unity-gain frequency = 1/(2*pi*R*C) ~ 15.9 kHz
* Opamp modeled as high-gain VCVS (E source)
*

V1 in 0 DC 0 AC 1
C1 in inv 1n
R1 inv out 10k
E1 out 0 0 inv 100k

.AC DEC 20 1 100MEG

.END
