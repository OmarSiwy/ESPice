* E ... LAPLACE is a behavioural form ESPice does not build: an error,
* never a node named "laplace". Oracle: input contract (HSPICE only).
* Expected results: laplace_source.expected.json
v1 a 0 1
e1 b 0 laplace a 0 1 / 1 1e-3
r2 b 0 1k
.op
.end
