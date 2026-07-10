* Phase noise with flicker upconversion (.phasenoise METHOD=0 and 1): the
* lc_oscillator Van der Pol tank (L = 25.330296u, R = 10k, cubic
* conductance g1 = 7e-4, g3 = 8e-4, so A = 1 V) tuned by a charge source
* Q = C0 (1 + k V(ctl)) V(t), C0 = 1n, k = 0.05. A JFET (VGS = 0,
* ID = 4 mA, gm = 4 mS, drain flicker KF ID / f) sinks its current from
* ctl through a noiseless 1k from 10 V, so V(ctl) = 6 V, C = 1.3 nF and
* f0 = 877.058 kHz.
* Oracle: analytic. The PPV at the tank is v_t = -sin(w0 t)/(C A w0); a
* current at ctl moves V(ctl) by Rc and the tank charge by C0 k v Rc, so
* the PPV at ctl is v_c = Rc C0 k v dv_t/dt = -(Rc k C0 / C) cos^2(w0 t).
* Phase diffusion c(fm) = kT/(R C^2 A^2 w0^2) + <v_c^2> (8/3 kT gm)/2
* + <v_c>^2 KF ID / (2 fm), with <v_c^2> = (3/8)(Rc k C0/C)^2 and
* <v_c> = -(Rc k C0)/(2C) (flicker upconverts through the PPV's mean), and
* L(fm) = f0^2 c / (pi^2 f0^4 c^2 + fm^2) at 27 degC. METHOD=1 (periodic
* noise at f0 + fm over the carrier power) adds the amplitude noise,
* under 0.001 dB at these offsets.
* Expected results: varactor_flicker.expected.json
L1 t 0 25.330296u
Bc t 0 Q=1n*(1+0.05*V(ctl))*V(t)
R1 t 0 10k
Bneg t 0 I=-7e-4*V(t)+8e-4*V(t)*V(t)*V(t)
vdd dd 0 10
rc dd ctl 1k noisy=0
j1 ctl 0 0 jm
.model jm njf vto=-2 beta=1e-3 kf=1e-18 af=1
.hbosc v(t) 877k 7
.phasenoise v(t) dec 1 10 10k
.phasenoise v(t) dec 1 10 10k method=1
.end
