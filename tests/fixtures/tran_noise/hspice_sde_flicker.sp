* HSPICE .trannoise METHOD=SDE with flicker noise [CR .TRANNOISE]: the
* jfet_flicker drain (VGS = 0, ID = BETA VTO^2 = 4 mA, KF ID / f) into a
* noiseless 1k load, no capacitance, so every step's noise is fresh: from
* the first step on, Var v(d) = R^2 (KF ID ln(FMAX / FMIN) + 8/3 kT gm FMAX)
* with gm = 2 BETA |VTO| = 4 mS, FMIN = 1 MHz, FMAX = 1/TSTEP = 1 GHz and
* 25 degC. Oracle: analytic; the flicker poles' variances sum to exactly
* KF ID ln(FMAX / FMIN) for AF = 1, and the white part is S / (2h).
* Expected results: hspice_sde_flicker.expected.json
vdd dd 0 10
rl dd d 1k noise=0
j1 d 0 0 jm
.model jm njf vto=-2 beta=1e-3 kf=1e-9 af=1
.tran 1n 200n
.trannoise v(d) method=sde fmin=1meg
.end
