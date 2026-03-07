* .options tnom is the model card's extraction temperature when the card omits it.
* Expected results: options_tnom.expected.json
* Origin: benchmark/fixtures/regression/options_tnom/circuit.sp
* ngspice: the card is DEGREES CELSIUS (cktsopt.c:71 `TSKnomTemp = val + CONSTCtoK`),
* it defaults to 300.15 K = 27 degC (cktntask.c:127), it reaches the circuit as
* CKTnomTemp (cktdojob.c:53), and every model setup spends it the same way —
* `if (!tnomGiven) tnom = ckt->CKTnomTemp` (diosetup.c:219, mos1temp.c:42,
* bjttemp.c:43, b4set.c:1950). It is independent of `.options temp`, which is
* where the circuit is RUN (OPT_TEMP, the next case in cktsopt.c).
*
* D1/M1/Q1 give no TNOM, so they follow the option: at 50 degC nominal and 100 degC
* operating the temperature terms are built over a 50 K span, not a 73 K one.
* D2 pins the precedence — a card TNOM must still win, so i(vd2) is the answer the
* whole deck would have given at the 27 degC default.
.options tnom=50
.temp 100

Vd1 d1 0 0.6
D1 d1 0 dm
Vd2 d2 0 0.6
D2 d2 0 dm27

Vg g 0 2
Vdd dd 0 3
M1 dd g 0 0 nm l=10u w=100u

Vbe b 0 0.7
Vce c 0 2
Q1 c b 0 qm

.model dm    d(is=1e-14 n=1.0 xti=3.0 eg=1.11 rs=0)
.model dm27  d(is=1e-14 n=1.0 xti=3.0 eg=1.11 rs=0 tnom=27)
.model nm    nmos(level=1 vto=0.8 kp=50u gamma=0.5 phi=0.6 lambda=0.01)
.model qm    npn(is=1e-16 bf=100 vaf=50 ne=1.5 ise=1e-14 xti=3.0 eg=1.11)
.op
.end
