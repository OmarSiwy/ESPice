* SCR/Thyristor Latchup — Regenerative Feedback Convergence Test
*
* Two complementary BJTs (NPN + PNP) in four-layer PNPN structure
* Regenerative positive feedback makes convergence very difficult
* Gate trigger pulse fires the SCR; once latched, it stays on
*
* Anode (a) -- PNP emitter
* Cathode (k) -- NPN emitter
* Gate (g) -- NPN base

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)
.MODEL PNP1 PNP (BF=80 IS=1e-15 VAF=80 RB=15 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.5n TR=8n)

* Supply and load
VCC anode 0 DC 10
R_load anode a 100

* PNP transistor: emitter=a, base=pb, collector=pc
Q1 pc pb a PNP1

* NPN transistor: collector=nc, base=nb, emitter=k
Q2 nc nb k NPN1

* Cross-coupling: PNP collector drives NPN base, NPN collector drives PNP base
* Q1 collector (pc) -> Q2 base (nb)
R_cross1 pc nb 10
* Q2 collector (nc) -> Q1 base (pb)
R_cross2 nc pb 10

* Cathode to ground
R_cathode k 0 1

* Gate trigger pulse: fires SCR at t=100ns
V_gate gate 0 PULSE(0 2 100n 5n 5n 50n 1u)
R_gate gate nb 100

* Nodeset hints: guide DC OP toward the SCR OFF state.
* Q1 PNP OFF: emitter(a)~10V, base(pb)~10V (VEB≈0), collector(pc) low.
* Q2 NPN OFF: collector(nc) high, base(nb)~0V (VBE≈0), emitter(k)~0V.
* Cross-coupling: V(pb) fed from nc via R_cross2, V(nb) fed from pc via R_cross1.
.NODESET V(a)=9.9 V(pb)=9.5 V(pc)=0.1 V(nb)=0.1 V(nc)=9.5 V(k)=0.0 V(gate)=0.0

.TRAN 1n 1u

.END
