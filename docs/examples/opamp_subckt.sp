Inverting amplifier with an opamp subcircuit
* A single-pole opamp: open-loop gain a0, pole at fp, output resistance rout.
* The pole node is p1: "pole" is an E-card keyword in that slot.
.subckt opamp inp inn out a0=100k fp=10 rout=10
E1 int 0 inp inn {a0}
R1 int p1 {1/(2*3.14159265*fp*1u)}
C1 p1 0 1u
E2 drv 0 p1 0 1
Ro drv out {rout}
.ends opamp

.param rin=1k rf=10k
VIN in 0 DC 0.1 AC 1
R1 in inv {rin}
R2 inv out {rf}
X1 0 inv out opamp a0=200k
RL out 0 10k
.op
.tf v(out) VIN
.ac dec 10 1 10meg
.end
