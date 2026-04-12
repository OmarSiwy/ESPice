* Open-Ended Transmission Line — Full Reflection
*
* Lossless ideal T-line with Z0=50, TD=1ns
* Source impedance = 50 ohm, load = open (1e9 ohm)
* Reflection coefficient = +1: pulse doubles at open end
* Reflected wave returns to source after 2*TD = 2ns

V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
T1 n1 0 n2 0 Z0=50 TD=1n
RL n2 0 1e9

.TRAN 0.05n 15n

.END
