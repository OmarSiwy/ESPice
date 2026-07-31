* BJT area on the instance card (#113): a bare number after the model name
* (INP2Q) and area= scale IS, the knees, the caps and 1/RB, 1/RE, 1/RC.
* Q1 positional area 4, Q2 area=3, Q3 a PNP with positional area 2.5,
* Q4 the same NPN at area 1 as the reference.
VB b 0 0.65
VC c 0 2
VE e 0 -0.65
Q1 c b 0 qn 4
Q2 c b2 0 qn area=3
VB2 b2 0 0.65
Q3 0 0 e qp 2.5
Q4 c b4 0 qn
VB4 b4 0 0.65
.model qn NPN IS=1e-16 BF=100 RB=10 RE=1 RC=5 IKF=1m VAF=50 ISE=1e-15
.model qp PNP IS=2e-16 BF=60 RB=20 RE=2 RC=8 IKF=0.5m
.op
.end
