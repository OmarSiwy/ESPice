* ngspice line syntax end to end: comments, continuations, scale factors
* Expected results: ngspice_lines.expected.json
//  a line holding only a // comment is a comment line
+ so this continuation continues nothing
.temp 27
.opts reltol=1e-4
.subckt div a b params: rt=1k
r1 a b {rt} ; a semicolon comment
r2 b 0 {rt} // a slash comment
.ends div
v1 in 0 2 $ a dollar comment after a blank
x1 in mid div params: rt=2k
r3 in 0 \\
1e6mil
.op
.end
