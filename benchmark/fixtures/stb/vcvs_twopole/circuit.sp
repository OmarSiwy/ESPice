* STB fixture: two-pole VCVS loop, resistive feedback divider.
* Loop gain T ≈ 1000/11 / ((1+jwR1C1)(1+jwR5C2)), finite phase margin.
Vin in 0 DC 0
R4 in sum 1k
E1 amp 0 sum 0 1000
R1 amp p1 1k
C1 p1 0 1u
R5 p1 p2 10k
C2 p2 0 1n
Vprb p2 fb DC 0
R2 fb sum 10k
R3 fb 0 1k
.stb Vprb dec 10 0.1 10meg
.end
