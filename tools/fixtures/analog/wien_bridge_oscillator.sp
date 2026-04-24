* Wien Bridge Oscillator
*
* VCVS gain element with RC Wien bridge feedback network
* R=10k, C=10n -> f_osc = 1/(2*pi*R*C) ~ 1.59 kHz
* Gain element set slightly above 3 for sustained oscillation
*

* Power supply
VCC vcc 0 DC 12
VEE vee 0 DC -12

* --- Wien bridge feedback network (positive feedback to non-inv input) ---
* Series RC arm
R1 out n1 10k
C1 n1 npos 10n

* Parallel RC arm
R2 npos 0 10k
C2 npos 0 10n

* --- Gain setting resistors (negative feedback) ---
* Gain = 1 + Rf/Rg = 1 + 20.5k/10k ~ 3.05 (slightly above 3 for oscillation)
RG ninv 0 10k
RF ninv out 20.5k

* --- Opamp (VCVS model) ---
E1 out 0 npos ninv 100k

* Small initial perturbation to start oscillation
VKICK npos nposx DC 0.001
RKICK nposx 0 100MEG

.TRAN 1u 5m

.END
