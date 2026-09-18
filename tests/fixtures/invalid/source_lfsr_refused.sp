* HSPICE LFSR is refused naming the card, not run as DC 0 (#72).
V1 a 0 lfsr(0 1 0 1n 1n 10n 7 1)
R1 a 0 1k
.tran 1n 10n
.end
