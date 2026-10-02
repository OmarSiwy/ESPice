* Phase noise with amplitude noise (.phasenoise METHOD=1 and 2): a Van der
* Pol LC tank (L = 25.330296u, C = 1n, R = 10k) with a weak cubic
* conductance g1 = 1.6e-4, g3 = 8e-5, so A = sqrt(4 (g1 - 1/R)/(3 g3)) = 1 V
* and amplitude deviations relax at gamma = (g1 - 1/R)/C = 6e4 /s.
* Oracle: analytic, narrowband envelope of the tank. The resistor's 4kT/R
* splits into quadrature (phase: dphi/dt = n_q/(2 C A)) and in-phase
* (amplitude: da/dt = -gamma a + n_i/(2 C)) parts, each 2 x 4kT/R
* one-sided, so the noise at f0 + fm over the carrier power A^2/2 is
* L(fm) = kT/(R C^2 A^2) [1/w^2 + 1/(gamma^2 + w^2)], w = 2 pi fm, at
* 27 degC: phase noise plus an amplitude part that reaches the phase part
* above gamma / 2 pi = 9.5 kHz. The envelope model is good to O(fm/f0)
* and O(eps), eps = (g1 - 1/R)/(w0 C) = 0.01. METHOD=2 stitches METHOD=0
* below the first offset where the two agree within 0.5 dB to METHOD=1
* above it; here they agree from 1 kHz, so it is METHOD=1.
* Expected results: am_noise.expected.json
L1 t 0 25.330296u
C1 t 0 1n
R1 t 0 10k
Bneg t 0 I=-1.6e-4*V(t)+8e-5*V(t)*V(t)*V(t)
.hbosc v(t) 1meg 7
.phasenoise v(t) dec 2 1k 10k method=1
.phasenoise v(t) dec 2 1k 10k method=2
.end
