* HSPICE .trannoise with flicker noise [CR .TRANNOISE]: two JFETs at
* VGS = 0 each sink ID = BETA VTO^2 = 4 mA from a 1k load, with drain
* flicker noise KF ID / f. Oracle: analytic; v(d1) = v(d2) = 10 - 4 = 6 V.
* Unfiltered, the load turns the noise into v(d1) variance R^2 KF ID
* ln(FMAX / FMIN) = 1e6 * 1e-9 * 4e-3 * ln(1e3) = 2.763e-5 V^2 between
* FMIN = 1 MHz and FMAX = 1/TSTEP = 1 GHz. At d2 a 15.915 pF cap puts a
* 10 MHz pole on it: R^2 KF ID [ln f - ln(1 + (f/fc)^2)/2] from FMIN to
* FMAX = 9.230e-6 V^2. White noise of the same power would give 20x less
* at d2. Channel thermal noise (8/3 kT gm R^2 FMAX) adds 0.2 % at d1.
* Expected results: jfet_flicker.expected.json
vdd dd 0 10
rl1 dd d1 1k noise=0
j1 d1 0 0 jm
rl2 dd d2 1k noise=0
cd d2 0 15.915p
j2 d2 0 0 jm
.model jm njf vto=-2 beta=1e-3 kf=1e-9 af=1
.tran 1n 20u
.trannoise v(d1) fmin=1meg seed=7
.end
