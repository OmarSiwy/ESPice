* RLC Bandpass — parallel RLC load, f0 = 1/(2*pi*sqrt(LC)) = 5.033 MHz
* V1 drives through R1 into a parallel L1||C1 load.
* At resonance Z_load -> inf, V_out -> V_in.
V1 in 0 DC 0 AC 1
R1 in out 50
L1 out 0 1u
C1 out 0 1n
.AC DEC 20 1k 100MEG
.END
