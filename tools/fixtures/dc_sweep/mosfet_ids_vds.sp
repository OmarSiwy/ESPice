* NMOS Output Characteristics (Ids vs Vds Family of Curves)
* Sweep VDS 0 to 3.3V, step VGS from 0.5V to 3.3V in 0.5V steps

VDD d 0 DC 0
VGS g 0 DC 1

M1 d g 0 0 NMOD W=10u L=1u

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)

.DC VDD 0 3.3 0.01 VGS 0.5 3.3 0.5

.END
