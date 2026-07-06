* An E-element VALUE={...} followed by HSPICE modifiers: the braced field is
* the whole expression, and SCALE applies to it.
* Expected results: value_modifier.expected.json
* Oracle (analytic), v(a) = 0.5: e1 = 3 * (2 v(a)) = 3; e2 = min(2 v(a), 0.4)
* through MAX=0.4 = 0.4.
va a 0 0.5
e1 o1 0 value={2*v(a)} scale=3
r1 o1 0 1k
e2 o2 0 value={2*v(a)} max=0.4
r2 o2 0 1k
.op
.end
