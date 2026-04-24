* Mismatched Transmission Line — 50 Ohm into 200 Ohm Load
*
* Lossless ideal T-line with Z0=50, TD=1n
* Source impedance = 50 ohm, load = 200 ohm
* Reflection coefficient = (200-50)/(200+50) = 0.6
* Partial reflections create staircase waveform

V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
T1 n1 0 n2 0 Z0=50 TD=1n
RL n2 0 200

.TRAN 0.05n 30n

.END
