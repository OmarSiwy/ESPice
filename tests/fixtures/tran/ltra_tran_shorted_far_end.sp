* X01 pending fixture: LTRA step into a near-short (RL = 0.05 ohm), the opposite
* discontinuity from ltra_tran_mismatched_load.  Same line: Z0 = 50, Td = 10 ns.
* GammaL = (0.05-50)/(0.05+50) = -49.95/50.05 = -0.998001998001998, GammaS = 0.
* Hand derivation of the 1 V step:
*   incident Vi = 0.5 V
*   0 < t < 2Td  v(a) = 0.5
*   t > Td       v(b) = Vi*(1+GammaL) = 0.5*0.001998001998002 = 0.000999000999001
*   t > 2Td      v(a) = Vi*(1+GammaL) = 0.000999000999001
* Final DC check: 0.05/(50+0.05) = 0.000999000999001, identical.  The near-total
* sign inversion is the point: a model that loses the reflection sign settles at
* 0.999 or 0.5 instead, three orders of magnitude away.
* Independent ngspice-44.2 agreement at the sampled times: <= 4.1e-8.
* Expected results: ltra_tran_shorted_far_end.expected.json
Vin in 0 PULSE(0 1 0 10p 10p 500n 1u)
Rs in a 50
O1 a 0 b 0 lline
RL b 0 0.05
.model lline LTRA(r=1e-6 l=250n g=0 c=100p len=2 rel=1)
.tran 20p 45n 0 20p
.end
