* HSPICE .sample [CR .SAMPLE]: RC thermal noise, R = 1k to a grounded
* source and C = 1 nF
* (fc = 159.155 kHz), sampled at FS = 1 MHz with no integrator, folding
* every band up to MAXFLD * FS = 10 MHz. Oracle: analytic; onoise_sampled^2
* at f is the sum over k of S(|f + k FS|) for 0 < |f + k FS| <= 10 MHz, with
* S(g) = 4kTR / (1 + (g / fc)^2) at 25 degC; the unsampled spectrum is S(f).
* Expected results: sample_rc.expected.json
vs in 0 dc 0 ac 1
r1 in out 1k
c1 out 0 1n
.ac dec 10 1k 1meg
.noise v(out) vs
.sample fs=1meg maxfld=10 beta=0
.end
