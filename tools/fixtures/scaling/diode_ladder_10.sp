* Diode Ladder — 10 diodes in series
V1 in 0 DC 5

.MODEL DMOD D (IS=1e-14 N=1 BV=100 RS=10)

D1 in n1 DMOD
D2 n1 n2 DMOD
D3 n2 n3 DMOD
D4 n3 n4 DMOD
D5 n4 n5 DMOD
D6 n5 n6 DMOD
D7 n6 n7 DMOD
D8 n7 n8 DMOD
D9 n8 n9 DMOD
D10 n9 out DMOD

RLOAD out 0 1k

.OP
.DC V1 0 10 0.1
.END
