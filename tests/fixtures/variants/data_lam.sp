* HSPICE external .data, column-laminated (LAM): l1.dat holds rl and
* l2.dat holds v1, side by side row for row; l2.dat is one row short, so
* the last row reads 0 for v1. The first FILE= sits on the .data line.
* Oracle: analytic, v(b) = v1 rl / (1k + rl) per row.
* Expected results: data_lam.expected.json
.param rl=1k
v1 a 0 1
r1 a b 1k
r2 b 0 rl
.data rows LAM FILE='data_lam.assets/l1.dat' rl=1
+ FILE='data_lam.assets/l2.dat' v1=1
.enddata
.dc data=rows
.end
