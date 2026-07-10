* HSPICE .trannoise SAMPLES= [RF Ch.9]: three Monte Carlo runs from SEED=1,
* of which index 1 is the noiseless run. A 1k resistor's thermal noise on
* 1 pF (tau = 1 ns) at 25 degC, stepped at h = 50 ps for 10 us.
* Oracle: analytic. Sample 1 stays at 0 V. Samples 2 and 3 are stationary
* with the backward-Euler variance b^2 (2kTG/h) / (1 - a^2) =
* kT/C * 2(h/tau) / ((1 + h/tau)^2 - 1) = 0.97561 kT/C = 4.0161e-9 V^2
* (a, b as in hspice_sde_rc). Over T = 10 us the time-weighted variance of
* an Ornstein-Uhlenbeck record has relative standard deviation
* sqrt(2 tau / T) = 1.41 %; the band is +/- 6 of those, 8.5 %.
* Expected results: hspice_samples.expected.json
r1 out 0 1k
c1 out 0 1p
.tran 100p 10u
.trannoise v(out) samples=3 seed=1
.end
