* HSPICE W element: two single lossy lines, 50 ohm source, 0.2 m, 100 ohm
* load. w1 has skin effect (Rs), w2 adds dielectric loss (Gd).
* Expected results: w_element.expected.json
* Oracle (analytic): DC is the series R0*l divider; AC is the exact ABCD
* chain of each line, Z = R0 + Rs sqrt(f)(1+j) + j w L0, Y = Gd f + j w C0,
* gamma = sqrt(ZY), Zc = Z/gamma. The W element runs a rational fit of Yc and
* of the delay-extracted propagation (docs/devices/w-s-elements.md): w1
* matches to 5e-5, w2 to 5e-2, because Gd f with a constant C0 is not causal
* and no rational (causal) model reaches it.
v1 in 0 dc 1 ac 1
rs1 in a 50
w1 a 0 b 0 rlgcmodel=skin n=1 l=0.2
rl1 b 0 100
rs2 in c 50
w2 c 0 d 0 rlgcmodel=diel n=1 l=0.2
rl2 d 0 100
.model skin w modeltype=rlgc n=1 lo=300n co=120p ro=5 rs=1m
.model diel w modeltype=rlgc n=1 lo=300n co=120p ro=5 rs=1m gd=1p
.op
.ac dec 2 1meg 10g
.end
