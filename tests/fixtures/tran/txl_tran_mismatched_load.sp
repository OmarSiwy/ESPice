* X01 pending fixture: TXL step into RL = 3*Z0, the Y-card twin of
* ltra_tran_mismatched_load.  Same electrical line (Z0 = 50, Td = 10 ns) and the
* same Bergeron algebra, so the two fixtures must agree with each other as well as
* with their own expected values; any divergence isolates the Pade fit from the
* LTRA convolution.
* GammaL = (150-50)/(150+50) = +0.5, GammaS = 0, incident Vi = 0.5 V.
*   t =  5 ns  v(a) = 0.5    v(b) = 0
*   t = 15 ns  v(a) = 0.5    v(b) = Vi*(1+GammaL) = 0.75
*   t = 25 ns  v(a) = Vi*(1+GammaL) = 0.75   v(b) = 0.75
*   t = 44 ns  v(a) = 0.75   v(b) = 0.75     (DC check 150/200 = 0.75)
* Independent ngspice-44.2 agreement at the sampled times: <= 1.2e-11.
* Expected results: txl_tran_mismatched_load.expected.json
Vin in 0 PULSE(0 1 0 10p 10p 500n 1u)
Rs in a 50
Y1 a 0 b 0 ymod
RL b 0 150
.model ymod txl R=1e-6 L=250n G=0 C=100p length=2
.tran 20p 45n 0 20p
.end
