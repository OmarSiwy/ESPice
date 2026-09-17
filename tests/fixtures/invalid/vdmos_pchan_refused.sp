* A P-channel VDMOS is refused naming the card (#75): vdmos.va has no
* polarity parameter, and running it N-channel is wrong (ngspice-45: 8 A).
VD d 0 -5
VG g 0 -5
M1 d g 0 vm
.model vm vdmos pchan vto=-1 kp=1
.op
.end
