* X01 pending fixture: LTRA step response into a mismatched load (RL = 3*Z0).
* Z0 = sqrt(250n/100p) = 50 ohm, Td = 2*sqrt(250n*100p) = 10 ns, r=1e-6 makes
* the line lossless to within alpha*L = r*len/(2 Z0) = 2e-8 Np.
* Reflection coefficients: GammaL = (150-50)/(150+50) = +0.5, GammaS = 0 (Rs=Z0).
* Bergeron hand derivation of the 1 V step (10 ps edge at t=0):
*   incident wave    Vi   = 1 * Z0/(Rs+Z0) = 0.5 V, launched at t=0
*   0 < t < 2Td      v(a) = 0.5                       (nothing has come back)
*   t > Td           v(b) = Vi*(1+GammaL) = 0.75      (incident + reflected)
*   t > 2Td          v(a) = Vi + GammaL*Vi = 0.75     (reflection absorbed by Rs)
* Final DC check: 150/(50+150) = 0.75, consistent with the t > 2Td plateau.
* Samples sit in the middle of plateaus so the runner's linear interpolation
* between accepted points is exact.  Independent ngspice-44.2 agreement: <= 1.4e-8.
* Expected results: ltra_tran_mismatched_load.expected.json
Vin in 0 PULSE(0 1 0 10p 10p 500n 1u)
Rs in a 50
O1 a 0 b 0 lline
RL b 0 150
.model lline LTRA(r=1e-6 l=250n g=0 c=100p len=2 rel=1)
.tran 20p 45n 0 20p
.end
