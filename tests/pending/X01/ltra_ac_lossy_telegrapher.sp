* X01 pending fixture: AC of a genuinely lossy LTRA against the closed-form
* telegrapher solution.  r=5 ohm/m over len=2 gives R_total=10 ohm, so this is
* not a perturbation of the lossless line: at 12.5 MHz |v(b)| = 0.45416048
* instead of 0.5 and v(a) = 0.5296370277-j0.0281790518 instead of 0.5.
* CORRECTED AFTER REVIEW: the line above previously read "|v(b)| = 0.4543", a
* number that is not |0.320461585-0.321816898j|.  Re-derived from the tabulated
* row itself: |v(b)| = sqrt(0.32046158459058616^2 + 0.3218168980723724^2)
*                    = sqrt(0.102695... + 0.103566...) = 0.4541604816397318.
* Nothing else in the deck or its oracle changes; the tabulated complex values
* were and are correct.
* Derivation (per frequency, w = 2 pi f, Z = r+jwl, Y = g+jwc, L = len):
*   gamma = sqrt(Z*Y), Zc = sqrt(Z/Y), gL = gamma*L
*   Zin = Zc*(RL + Zc*tanh(gL))/(Zc + RL*tanh(gL))
*   v(a) = Vs*Zin/(Rs+Zin)
*   v(b) = v(a)/(cosh(gL) + (Zc/RL)*sinh(gL))
*   i(vin) = -(Vs - v(a))/Rs
* These are exact; an independent ngspice-44.2 run of this deck matches every
* value to <= 9.5e-16.  The DC limit of this deck is R_total = r*len = 10 ohm,
* loop 110, v(a) = 60/110 = 0.545454545454545 and v(b) = 50/110 = 0.454545454545455,
* both purely real.  Every tabulated row is complex and none matches those, so a
* line stamped as its DC resistance fails all eight rows.
* Expected results: ltra_ac_lossy_telegrapher.expected.json
Vin in 0 AC 1
Rs in a 50
O1 a 0 b 0 lline
RL b 0 50
.model lline LTRA(r=5 l=250n g=0 c=100p len=2 rel=1)
.ac lin 8 12.5meg 100meg
.end
