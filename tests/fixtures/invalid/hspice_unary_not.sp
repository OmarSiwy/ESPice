* HSPICE has no unary `!` (#203): its manual's operator table (UG08
* pp. 279-283; dev/research/hspice-syntax.md X2) lists `!=` but no logical
* not, so ESPice refuses the deck by name. The legal neighbour is
* hspice/hspice_expressions.sp's t1, `(a!=b)`.
v1 a 0 1
r1 a 0 '1k*(!0)'
.op
.end
