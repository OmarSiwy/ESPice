RC delay spread over Monte Carlo trials
* R varies by 3 % (one sigma). The 50 % crossing is at R C ln 2 = 693 ns.
.param rv=agauss(1k, 30, 1)
V1 in 0 PWL(0 0 1p 1)
R1 in out {rv}
C1 out 0 1n
.option seed=3
.tran 10n 2u sweep monte=50
.meas tran tc WHEN v(out)=0.5 RISE=1
.end
