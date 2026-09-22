* X01 pending fixture: TXL (Y card) matched step, pinning delay and amplitude.
* The Y card routes to txl_native, whose Hough/SWEC [3/3] Pade fit is a different
* algorithm from LTRA convolution; a matched near-lossless line is the case where
* the Pade approximation must be transparent.
* Z0 = sqrt(L/C) = sqrt(250n/100p) = 50 ohm.  sqrt(L*C) = sqrt(250e-9*100e-12)
* = 5 ns/m, so Td = length * 5 ns/m = 2 m * 5 ns/m = 10 ns.
* Rs = RL = Z0, so GammaS = GammaL = 0 and the exact answer is a plain delay:
*   v(a)(t) = 0.5 for t > 10 ps (the source edge),  v(b)(t) = v(a)(t - 10 ns).
* Hand-derived samples:
*   t =  5.0 ns  v(a) = 0.5   v(b) = 0     (wavefront has not arrived)
*   t =  9.9 ns  v(a) = 0.5   v(b) = 0     (100 ps before arrival: pins Td from below)
*   t = 12.0 ns  v(a) = 0.5   v(b) = 0.5
*   t = 25.0 ns  v(a) = 0.5   v(b) = 0.5   (no reflection ever returns)
*   t = 44.0 ns  v(a) = 0.5   v(b) = 0.5
* R = 1e-6 keeps alpha*L = 2e-8 Np.  Independent ngspice-44.2 agreement: <= 5.1e-12.
* Expected results: txl_tran_matched_step.expected.json
Vin in 0 PULSE(0 1 0 10p 10p 500n 1u)
Rs in a 50
Y1 a 0 b 0 ymod
RL b 0 50
.model ymod txl R=1e-6 L=250n G=0 C=100p length=2
.tran 20p 45n 0 20p
.end
