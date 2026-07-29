Diode forward voltage from a library corner
* .lib FILE SECTION pulls one section; .include pulls a whole file.
.lib "models.lib" slow
.include "divider.inc"
I1 0 a 1m
D1 a 0 dlib
X1 a mid 0 divider
.op
.end
