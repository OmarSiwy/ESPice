* Common-Source Amplifier Bias Sweep — find optimal bias for max gain
.model nch NMOS(level=1 VTO=0.7 KP=110u GAMMA=0.4 LAMBDA=0.04 PHI=0.65)
Vdd vdd 0 DC 3.3
Vgs gate 0 DC 1.0
Rd vdd drain 10k
Rs source 0 1k
Cs source 0 100u
M1 drain gate source 0 nch W=10u L=1u
.dc Vgs 0 3.3 0.01
.end
