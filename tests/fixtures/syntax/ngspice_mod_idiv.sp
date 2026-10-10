* `%` (modulo) and `\` (integer division) in expressions, blanks around
* the operator included (#180).
* Expected results: ngspice_mod_idiv.expected.json
* Each source drives one resistor, so i(vk) = -1 / Rk.
.param p1=10 %3
.param p2=10 \ 3
v1 n1 0 1
r1 n1 0 {1k*p1}
v2 n2 0 1
r2 n2 0 {1k*p2}
* An unbraced value after `key=` is an ESPice extension (tests/grammar/
* ngspice.peg, pairexpr): `%` and `\` continue it as `*` and `/` do.
v3 n3 0 1
r3 n3 0 r=7k %4k
v4 n4 0 1
r4 n4 0 r=7k \ 2
* With no blank, ngspice reads `2k%3` as one token, INPevaluate's 2k with
* the rest ignored, since INPgetTok splits at neither `%` nor `\` (#200).
v5 n5 0 1
r5 n5 0 r=2k%3
v6 n6 0 1
r6 n6 0 r=3k\2
.op
.end
