* Differential Pair Over Coupled Transmission Lines
*
* Two parallel T-lines driven differentially
* Capacitive coupling (C12) between lines at near and far ends
* Tests common-mode and differential-mode signal integrity
* Source: differential pulse (+0.5V / -0.5V)

V1P inp 0 PULSE(0 0.5 0 0.1n 0.1n 5n 10n)
V1N inn 0 PULSE(0 -0.5 0 0.1n 0.1n 5n 10n)

RS1 inp n1 50
RS2 inn n2 50

T1 n1 0 n3 0 Z0=50 TD=1n
T2 n2 0 n4 0 Z0=50 TD=1n

* Capacitive coupling between lines (near end and far end)
C12a n1 n2 0.1p
C12b n3 n4 0.1p

RL1 n3 0 50
RL2 n4 0 50

.TRAN 0.05n 20n

.END
