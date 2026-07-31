* MOS1 with both bulk junctions hard forward-biased behind series
* resistance (#104). The gate is low, so the channel is off and the circuit
* is two IS = 1e-14 junctions (bi->di, bi->si) fed through RB from 5 V into
* RD = 0.07 and RS = 1 ohm. Plain Newton and gmin stepping cycle; the
* answer comes from source stepping.
* Oracle: an independent three-node Newton solve of
*   (5 - bi)/RB = Ibd + Ibs,  Ibd = di/RD,  Ibs = si/RS,
*   Ij = IS*(exp(vj/vt) - 1) + 1e-12*vj,  vt = k*300.15/q,
* converged to |F| < 3e-13 A:
*   v(bi) = 3.047027053487852   v(di) = 2.1249633022492214
*   v(si) = 2.192930504975506   i(vb) = -32.54954910853581
* ngspice 45 converges to v(di) = 2.12480, where its own bulk-drain law
* gives 30.736 A against the 30.354 A through RD: it accepts the clamped
* bias, the failure this deck guards (dev/devices/models.md).
VB b 0 5
VD d 0 0
VS s 0 0
VG g 0 1
RD d di 0.07
RS s si 1
RB b bi 0.06
M1 di g si bi nmod W=10u L=1u
.model nmod NMOS LEVEL=1 VTO=0.7 KP=1e-4
.op
.end
