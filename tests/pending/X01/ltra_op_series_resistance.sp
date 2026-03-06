* X01 pending fixture: LTRA DC operating point is a pure series resistance, and
* depends on r*len ALONE -- not on Z0 and not on Td.
*
* CORRECTED AFTER REVIEW.  The previous deck held one line only, and its three
* asserted numbers (v(a), v(b), i(vin)) are algebraically one number: with a
* single loop, i = -1/101 forces v(b) = 50*|i| and v(a) = v(b) + 1*|i|.  Any
* implementation that got the loop resistance right got all three, and the
* number it asserted is exactly the one the DC-resistance fallback -- the path
* that is WRONG for AC and is the subject of this row -- already returns.  The
* fixture therefore passed without exercising anything the row is about.
*
* The deck now carries a second, electrically different line whose DC answer
* must be bit-identical to the first.  That is a real identity, not a repeat:
*   lline : r=0.5   len=2  -> R = 1 ohm, Z0 = sqrt(250n/100p)  =  50 ohm,
*                             Td = len*sqrt(l*c) = 10 ns
*   lline2: r=0.125 len=8  -> R = 1 ohm, Z0 = sqrt(4u/400p)    = 100 ohm,
*                             Td = 8*sqrt(4u*400p)             = 320 ns
* Same r*len, twice the characteristic impedance, thirty-two times the delay.
* At DC the telegrapher equations degenerate to the lumped totals R*len and
* G*len; L and C carry no DC current, so Z0 and Td must cancel out completely.
* The two lines are the teeth: any DC stamp that is a function of Z0 or Td
* returns two DIFFERENT triples and fails at least one of them.  Worked out for
* the two plausible wrong stamps -- stamp the line at Z0: loop 50+50+50 = 150
* on line 1 gives v(a) = 100/150 = 0.666667, loop 50+100+50 = 200 on line 2
* gives v(a) = 150/200 = 0.75, so the two lines disagree with each other by
* 0.083; stamp it as a short (the ideal-`tline` DC limit): both lines give
* v(a) = 0.5, self-consistent but 4.95e-3 away from the asserted 0.504950495,
* 248x the 2e-5 rtol below.  Only "R = r*len, and nothing else" satisfies all
* six values at once.
*
* Hand derivation (identical for both lines).  R_line = r*len = 1 ohm exactly;
* loop = 50 + 1 + 50 = 101 ohm across 1 V:
*   i(vin) = -1/101 = -0.009900990099009901 A  (ngspice sign: out of the + node)
*   v(a)   = 51/101 = 0.504950495049505 V
*   v(b)   = 50/101 = 0.49504950495049505 V
* This value is ALSO what docs/native-transmission-line-migration.md reports the
* host returning for every AC frequency, so the AC fixtures must NOT equal it.
* Independent ngspice-44.2 agreement on all six values: exact (delta 0.0).
* Expected results: ltra_op_series_resistance.expected.json
Vin in 0 DC 1
Rs in a 50
O1 a 0 b 0 lline
RL b 0 50
Vin2 in2 0 DC 1
Rs2 in2 a2 50
O2 a2 0 b2 0 lline2
RL2 b2 0 50
.model lline  LTRA(r=0.5   l=250n g=0 c=100p len=2 rel=1)
.model lline2 LTRA(r=0.125 l=4u   g=0 c=400p len=8 rel=1)
.op
.end
