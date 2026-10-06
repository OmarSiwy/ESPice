Divider spread with agauss and a Monte Carlo DC
* agauss(nominal, variation, sigmas): 30 ohms is the 3-sigma spread.
.param r1v=agauss(1k, 30, 3) r2v=agauss(1k, 30, 3)
V1 in 0 DC 1
R1 in out {r1v}
R2 out 0 {r2v}
.option seed=7
.dc monte=200
.end
