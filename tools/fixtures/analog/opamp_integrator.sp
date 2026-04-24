* Opamp Integrator (C in Feedback)
*
* Transfer function: Vout/Vin = -1/(s*R1*C1)
* R1=10k, C1=1n -> unity-gain frequency = 1/(2*pi*R*C) ~ 15.9 kHz
* Opamp modeled as high-gain VCVS (E source)
*

V1 in 0 DC 0 AC 1
R1 in inv 10k
C1 inv out 1n
E1 out 0 0 inv 100k

.AC DEC 20 1 100MEG

.END
