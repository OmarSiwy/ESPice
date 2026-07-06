* A braced parameter that only starts a B or VALUE expression groups like
* parentheses; the rest of the line still belongs to the expression. It used
* to keep {g} alone and drop the rest.
* Expected results: bsource_brace_expr.expected.json
* Oracle (analytic), g = 2, v(a) = v(b) = 1:
*   b1  {g}*(v(a)+v(b))^3 = 2 * 8 = 16
*   e2  {g}*v(a)+1        = 3
*   b3  {g*v(a)}          = 2   (a lone braced field is its body)
.param g=2
va a 0 1
vb b 0 1
b1 o1 0 v={g}*(v(a)+v(b))^3
r1 o1 0 1k
e2 o2 0 value={g}*v(a)+1
r2 o2 0 1k
b3 o3 0 v={g*v(a)}
r3 o3 0 1k
.op
.end
