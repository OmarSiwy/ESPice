* HSPICE has no `%` operator (#203): its manual's operator table (UG08
* pp. 279-283, Table 19; dev/research/hspice-syntax.md X2) lists + - * /
* ** ^ and the comparisons and logicals only, so ESPice refuses the card
* by name instead of reading 10 and dropping the rest. The legal neighbour
* is r4 of hspice/hspice_expressions.sp, `r=6k * 2 / 3`.
v1 a 0 1
r1 a 0 '10 % 3'
.op
.end
