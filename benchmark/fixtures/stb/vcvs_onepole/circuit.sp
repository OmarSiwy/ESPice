* STB fixture: single-pole VCVS loop, resistive feedback divider.
* Loop gain T ≈ 100/11 ≈ 9.09, pole at 1/(2pi*1k*1u) ≈ 159 Hz.
Vin in 0 DC 0
R4 in sum 1k
E1 amp 0 sum 0 100
R1 amp p1 1k
C1 p1 0 1u
Vprb p1 fb DC 0
R2 fb sum 10k
R3 fb 0 1k
.stb Vprb dec 10 0.1 100k
.end
