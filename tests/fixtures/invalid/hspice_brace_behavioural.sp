* HSPICE quotes a behavioural expression (E VOL='...'); braces are name
* bytes (dev/research/hspice-syntax.md T2), so `VOL={...}` is no expression
* and ESPice refuses the card by name (#203). The legal neighbour is
* `e1 o 0 vol='v(a)*2'`.
v1 a 0 1
e1 o 0 vol={v(a)*2}
r1 o 0 1k
.op
.end
