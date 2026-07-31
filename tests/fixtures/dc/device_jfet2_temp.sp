* JFET level 2 follows the circuit temperature (#79): the circuit runs at
* 125 C; J1 takes it, J2 overrides it with temp=27, J3 sits dtemp=-50 below.
.options temp=125
VGS g 0 0
VDS d 0 1
J1 d g 0 jm
J2 d g 0 jm temp=27
J3 d g 0 jm dtemp=-50
.model jm NJF LEVEL=2 VTO=-1.5 BETA=1e-3 LAMBDA=0.02 IS=1e-14 RS=10 RD=10
.dc VGS -2 0.6 0.05
.end
