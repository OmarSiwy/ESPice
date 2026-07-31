* JFET in inverse mode (#49): the drain at -3 V, V(g,d) held at 0.5 V, so
* the channel runs source <- drain with overdrive vgd - VTO = 2.5 V and
* |vds| = 3 V > 2.5 V: saturation, Shichman-Hodges
*   i(vs) = -BETA*(vgd - VTO)^2 = -1e-4*6.25 = -0.625 mA (LAMBDA = 0).
* A limvds on the channel clamped the negative vds at -0.5 V even at the
* fixed point and gave -1.225 mA.
VD d 0 -3
VG g d 0.5
VS s 0 0
J1 d g s jm
.model jm NJF VTO=-2 BETA=1e-4 LAMBDA=0 IS=1e-14
.op
.end
