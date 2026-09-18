* HSPICE .step with .alter (#66): the base run keeps its step rows, and the .alter
* run steps again with its own change. i(v1) = -v/rv.
.param rv=1k
V1 a 0 1
R1 a 0 'rv'
.step param rv list 1k 2k
.op
.alter
V1 a 0 2
.end
