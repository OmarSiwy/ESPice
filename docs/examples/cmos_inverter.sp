CMOS inverter
.param vdd=1.8 wn=1u wp={2*wn}
VDD vdd 0 {vdd}
VIN in 0 DC 0 PULSE(0 {vdd} 1n 100p 100p 5n 10n)
M1 out in 0 0 nch W={wn} L=180n
M2 out in vdd vdd pch W={wp} L=180n
CL out 0 10f
.model nch NMOS(LEVEL=1 VTO=0.45 KP=200u LAMBDA=0.05 GAMMA=0.4 PHI=0.8)
.model pch PMOS(LEVEL=1 VTO=-0.45 KP=80u LAMBDA=0.05 GAMMA=0.4 PHI=0.8)
.dc VIN 0 1.8 0.01
.tran 10p 20n
.meas tran tphl TRIG v(in) VAL=0.9 RISE=1 TARG v(out) VAL=0.9 FALL=1
.end
