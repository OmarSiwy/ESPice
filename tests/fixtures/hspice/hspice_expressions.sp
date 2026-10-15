* HSPICE quoted expressions, functions, subcircuits and line syntax
* Expected results: hspice_expressions.expected.json
.options reltol=1e-4
.global vdd
.parameters a=2 b=3
.param f(x)='x*2'
.func g(x, y) 'x+y'
.param t1='(a<b) && !(a==b) || 0'
.param t2="a^3"
.param t3='a>b ? 10 : 20'
.subckt load n rv=1k
r1 n 0 'rv*t3/20'
.ends load
vdd vdd 0 1
x1 vdd load rv='f(g(1, 2))*1k'
v2 n2 0 1 $ a comment after a separator
r2 n2 0 '1k*t2' $ comment
v3 n3 0 1
r3 n3 0 \
'1k*t1'
* `*` and `/` continue an unquoted value across blanks; `%` and `\` are no
* HSPICE operators (#203, invalid/hspice_percent_operator.sp).
v4 n4 0 1
r4 n4 0 r=6k * 2 / 3
.op
.end
