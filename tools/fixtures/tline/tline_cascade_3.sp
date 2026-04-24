* Three Cascaded Transmission Lines with Different Impedances
*
* T1: Z0=50, TD=1ns
* T2: Z0=75, TD=1.5ns
* T3: Z0=100, TD=2ns
* Multiple reflections at each impedance boundary
* Source=50 ohm, Load=100 ohm (matched to last segment)

V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
T1 n1 0 n2 0 Z0=50 TD=1n
T2 n2 0 n3 0 Z0=75 TD=1.5n
T3 n3 0 n4 0 Z0=100 TD=2n
RL n4 0 100

.TRAN 0.05n 30n

.END
