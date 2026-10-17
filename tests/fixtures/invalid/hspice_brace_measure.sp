* HSPICE writes a measure's expression quoted or as par('...'); braces are
* name bytes (dev/research/hspice-syntax.md T2), so `at={1n}` is no
* expression and ESPice refuses the measure card by name instead of
* skipping it (#203). The legal neighbour is `at=1n`.
v1 a 0 pwl(0 0 2n 1)
r1 a 0 1k
.tran 0.1n 2n
.meas tran x find v(a) at={1n}
.end
