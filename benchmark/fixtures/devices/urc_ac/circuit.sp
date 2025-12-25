* URC (Uniform distributed RC line) AC frequency response.
* Tests distributed RC impedance vs frequency.
V1 in 0 DC 1 AC 1
U1 in out 0 umod L=100u N=10
RL out 0 10k
.model umod URC(K=1.5 FMAX=1G RPERL=1000 CPERL=1p)
.ac dec 20 1k 1G
.end
