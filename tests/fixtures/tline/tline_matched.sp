* Matched 50-Ohm Transmission Line
*
* Lossless ideal T-line with Z0=50, TD=1ns
* Source impedance = 50 ohm, load impedance = 50 ohm
* Perfect match: no reflections expected
* Pulse propagates cleanly from n1 to n2 with 1ns delay

V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
T1 n1 0 n2 0 Z0=50 TD=1n
RL n2 0 50

.TRAN 0.05n 15n

.END
