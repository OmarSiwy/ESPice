* Loop stability through a loaded break: Tian's loop gain is G1's return ratio
* Expected results: lstb_loaded_break.expected.json
G1 amp 0 y 0 0.01
RL amp 0 10000.0
CL amp 0 3.183e-08
Vprobe fb amp 0
Rf fb in 9000.0
Rin in 0 1000.0
Cin in 0 1e-07
E2 x 0 in 0 1
R2 x y 1k
C2 y 0 7.958e-08
.ac dec 10 10 100k
.lstb mode=single vsource=Vprobe
.end
