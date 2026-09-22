* ngspice expression operators, functions and conditionals, end to end
* Expected results: ngspice_expressions.expected.json
* Each source drives one resistor, so i(vk) = -1 / Rk.
.parameters a=2 b=3
.param f(x)={x*2}
.func g(x, y) {x+y}
.param t1={(a<b) && !(a==b) || 0}
.param t2={a**3}
.param t3={a>b ? 10 : 20}
.param t4={(a!=b) + (a<>b) + (a<=b) + (a>=b)}
v1 n1 0 1
r1 n1 0 {1k*t1}
v2 n2 0 1
r2 n2 0 {1k*t2}
v3 n3 0 1
r3 n3 0 {100*t3}
v4 n4 0 1
r4 n4 0 {1k*t4}
v5 n5 0 1
* The manual (§2.15) allows no .param inside an .if block: devices only.
.if (a==1)
r5 n5 0 7k
.elseif (a==2)
r5 n5 0 5k
.else
r5 n5 0 9k
.endif
v6 n6 0 1
r6 n6 0 {f(g(1, 2))*1k}
.op
.end
