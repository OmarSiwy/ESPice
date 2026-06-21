* JFET channel noise against 8/3 kT gm, with a noiseless load
* Expected results: jfet_channel.expected.json
* VGS = 0 sinks ID = BETA VTO^2 = 4 mA in saturation (VDS = 6 V), so
* gm = 2 BETA |VTO| = 4 mS. The 1k load is two 500 ohm halves switched
* off by both of ngspice's spellings, noisy=0 and noise=0 (res.c), so the
* output is the channel alone: sqrt(8/3 kT gm) * 1k at T = 300.15 K.
* Oracle: analytic; ngspice-45 prints the same 6.648522e-09.
vdd dd 0 10
rl1 dd x 500 noisy=0
rl2 x d 500 noise=0
vg g 0 0 ac 1
j1 d g 0 nj
.model nj njf vto=-2 beta=1e-3
.noise v(d) vg lin 1 1k 1k
.end
