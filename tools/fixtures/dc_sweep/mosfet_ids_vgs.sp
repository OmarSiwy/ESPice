* NMOS Transfer Characteristics (Ids vs Vgs)
* Fixed VDS=3.3V, sweep VGS from 0 to 3.3V

VDD d 0 DC 3.3
VGS g 0 DC 0

M1 d g 0 0 NMOD W=10u L=1u
RD d 0 100

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)

.DC VGS 0 3.3 0.01

.END
