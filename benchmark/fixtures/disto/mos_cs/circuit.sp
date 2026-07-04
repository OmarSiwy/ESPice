* DISTO fixture: MOS level-1 common-source distortion.
Vdd vdd 0 DC 5
Vin g 0 DC 1.5 AC 1 DISTOF1 0.05
Rd vdd d 2k
M1 d g 0 0 nm W=20u L=2u
.model nm NMOS(level=1 vto=0.7 kp=60u lambda=0.02)
.disto dec 10 1k 1meg
.end
