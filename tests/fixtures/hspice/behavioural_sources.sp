* Behavioural E/G/H forms lowered to B sources, against closed forms.
* Expected results: behavioural_sources.expected.json
* Oracle (analytic), with v(a) = 0.5, v(b) = 2, v(c) = 3, i(vb) = -2 mA:
*   E1 VALUE        2 v(a) + 1                                  = 2
*   E2 POLY(2)      1 + 2 va + 3 vb + 4 va^2 + 5 va vb + 6 vb^2 = 38  (SPICE 2G6 order)
*   G3 TABLE        (0,0) (1,2) (2,2), x = 0.5 sits on the first segment's
*                   straight part (corner half-width 0.1): i = 1, into 1 ohm
*   H4 VALUE        100 i(vb)                                   = -0.2
*   B5              temper at the default 27 degC               = 27
*   G8 VCR          a resistance of 2 v(c) = 6 ohm under 6 ohm from 6 V: v(o8) = 3
*   G9 VCCAP        a capacitance of 1e-6 v(c) = 3 uF under 1 kohm, AC at
*                   f = 1/(2 pi R C): v(o9) = 1/(1 + j) = 0.5 - 0.5 j
va a 0 0.5
vb b 0 2
rb b 0 1k
vc c 0 3
e1 o1 0 value={2*v(a)+1}
e2 o2 0 poly(2) a 0 b 0 1 2 3 4 5 6
g3 0 o3 table {v(a)} = (0,0) (1,2) (2,2)
r3 o3 0 1
h4 o4 0 value={i(vb)*100}
b5 o5 0 v=temper
vs8 s8 0 6
r8 s8 o8 6
g8 o8 0 vcr c 0 2
vin in 0 dc 0 ac 1
r9 in o9 1k
g9 o9 0 vccap c 0 1e-6
.op
.ac lin 1 53.05164769729845 53.05164769729845
.end
