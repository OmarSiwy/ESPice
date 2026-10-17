* HSPICE reads an unquoted expression only when it "begins with an
* alphabetic character and contains no spaces" (CR10 p. 238;
* dev/research/hspice-syntax.md X1), so `r=2*rv` needs quotes and ESPice
* refuses it by name (#203). Legal neighbours: r='2*rv' and r=rv*2
* (hspice/hspice_expressions.sp r4).
.param rv=1k
v1 a 0 1
r1 a 0 r=2*rv
.op
.end
