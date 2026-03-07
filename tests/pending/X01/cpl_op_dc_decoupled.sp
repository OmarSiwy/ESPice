* X01 pending fixture: CPL DC operating point.  At DC the coupled line reduces to
* the lumped matrices R*length and G*length; L and C do not conduct.  Here R is
* diagonal and G is zero, so the two conductors are exactly independent and every
* value is a rational number.
*
* CORRECTED AFTER REVIEW.  The previous deck held one P card, and the review is
* right that its conductor-1 triple is the same "DC resistance" answer this row
* accuses the host of returning everywhere.  A second, electrically different
* coupled line is now driven in parallel and must give a bit-identical answer:
*   cmod : R11=2   length=3  -> R = 6 ohm, Ze = sqrt((250n+150n)/(100p-60p)) = 100
*                               Zo = sqrt((250n-150n)/(100p+60p)) = 25
*                               Td = 3*sqrt(400n*40p) = 12 ns
*   cmod2: R11=0.5 length=12 -> R = 6 ohm, Ze = sqrt((1u+600n)/(1600p-960p)) = 50
*                               Zo = sqrt((1u-600n)/(1600p+960p)) = 12.5
*                               Td = 12*sqrt(1.6u*640p) = 384 ns
* Same R*length; both modal impedances halved; thirty-two times the delay.  A DC
* stamp that is a function of either eigen-impedance or of the delay cannot give
* the same answer on both cards, so the pair pins "DC sees R*length and G*length
* and nothing else" rather than merely re-stating one divider.
*
* Per-conductor series resistance = R11*length = 2*3 = 0.5*12 = 6 ohm.
* Conductor 1 loop: 10 + 6 + 40 = 56 ohm driven by 1 V.
*   i(v1) = -1/56 = -0.017857142857142856 A   (ngspice sign convention)
*   v(a1) = 1 - 10/56 = 46/56 = 0.8214285714285714 V
*   v(b1) = 40/56      = 0.7142857142857143 V
* Conductor 2 is driven by a 0 V source, so v(a2) = v(b2) = 0 and i(v2) = 0 --
* this is the second discriminator: a model that leaks DC across the L/C coupling
* (L12 = 150n and C12 = -60p are both large here), or that applies the off-diagonal
* R entry, moves conductor 2 off zero while conductor 1 carries 17.86 mA.
* Independent ngspice-44.2 agreement: <= 2.9e-12 (largest residual 2.852e-12 on
* v(b1)/v(b3); i(v1)/i(v3) agree to 2.4e-13).
* Expected results: cpl_op_dc_decoupled.expected.json
V1 in1 0 DC 1
V2 in2 0 DC 0
R1 in1 a1 10
R2 in2 a2 10
P1 a1 a2 0 b1 b2 0 cmod
RL1 b1 0 40
RL2 b2 0 40
V3 in3 0 DC 1
V4 in4 0 DC 0
R3 in3 a3 10
R4 in4 a4 10
P2 a3 a4 0 b3 b4 0 cmod2
RL3 b3 0 40
RL4 b4 0 40
.model cmod CPL
+R = 2 0 2
+L = 250n 150n
+     250n
+C = 100p -60p
+     100p
+G = 0 0 0
+length = 3
.model cmod2 CPL
+R = 0.5 0 0.5
+L = 1u 600n
+     1u
+C = 1600p -960p
+     1600p
+G = 0 0 0
+length = 12
.op
.end
