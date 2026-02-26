* BJT 1/f corner: base driven through 100k so the b-e generator has gain.
* KF/AF make flicker own the low decades and thermal+shot the high ones, so
* the sweep crosses the corner and checks the 1/f^EF shape, not just a level.
VCC vcc 0 DC 10
Vin in 0 DC 2.0 AC 1
RB in b 100k
RC vcc out 4.7k
Q1 out b 0 QN
.model QN NPN(IS=1e-16 BF=150 KF=2e-12 AF=1)
.noise V(out) Vin dec 10 10 1meg
.end
