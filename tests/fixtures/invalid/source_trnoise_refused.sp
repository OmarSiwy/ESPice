* TRNOISE is refused naming the card, not run as its DC value (#72).
* ngspice-45 draws white noise here (rms ~0.087 V over 1 us); ESPice has no
* transient noise source generator yet.
V1 a 0 dc 0 trnoise(0.1 1n 0 0)
R1 a 0 1k
.tran 1n 1u
.end
