* HSPICE dialect: {expr} is an expression, an ESPice extension (#153).
* Analytic: R1 = 2*rv = 2k, so i(v1) = -1 V / 2k = -0.5 mA; R2 = rv = 1k
* by a braced bare name, i(v2) = -1 mA.
.param rv=1k
V1 a 0 1
R1 a 0 {rv*2}
V2 b 0 1
R2 b 0 {rv}
.op
.end
