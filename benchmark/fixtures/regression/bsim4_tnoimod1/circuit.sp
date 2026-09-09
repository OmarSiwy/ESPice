* BSIM4 thermal-noise mode must preserve connected DC source/drain branches.
* Zero nrd/nrs, rdsmod=0: tnoimod=1 still requires the internal-node shorts.
Vdn dn 0 1
Vgn gn 0 1.2
Vdp dp 0 -1
Vgp gp 0 -1.2
Mn dn gn 0 0 nm l=1u w=10u nrd=0 nrs=0
Mp dp gp 0 0 pm l=1u w=10u nrd=0 nrs=0
.model nm nmos(level=54 tnoimod=1 rdsmod=0)
.model pm pmos(level=54 tnoimod=1 rdsmod=0)
.op
.end
