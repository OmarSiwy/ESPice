* NMOS Subthreshold Characteristics
* Sweep VGS from 0 to 1.5V in fine steps to observe subthreshold behavior
* VDS fixed at saturation to see clean Ids vs VGS curve

VDS d 0 DC 1.65
VGS g 0 DC 0

M1 d g 0 0 NMOD W=10u L=1u

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

.DC VGS 0 1.5 0.01

.END
