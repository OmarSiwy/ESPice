* PWL FILE= is refused naming the card, not run as DC 0 (#72).
V1 a 0 pwl file=nonexist.txt
R1 a 0 1k
.tran 1n 10n
.end
