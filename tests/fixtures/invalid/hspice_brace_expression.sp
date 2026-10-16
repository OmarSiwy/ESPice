* HSPICE reads braces as name bytes, not an expression (#203, reversing
* #153): the manual turns `{}` into `[]` inside names
* (dev/research/hspice-syntax.md T2). So `{rv*2}` and `{rv}` are names, and a
* resistor whose value is an unknown name is refused (UnresolvedParameter),
* as HSPICE refuses it. The legal neighbour is `R1 a 0 'rv*2'`.
.param rv=1k
V1 a 0 1
R1 a 0 {rv*2}
V2 b 0 1
R2 b 0 {rv}
.op
.end
