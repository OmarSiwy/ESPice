* Microstrip Approximation Using LTRA Model
*
* Models a PCB microstrip trace using lumped RLGC parameters
* R=2 ohm/unit (copper loss), L=300nH/unit, C=120pF/unit
* Length=0.1 units (short trace)
* Characteristic impedance ~ sqrt(L/C) ~ sqrt(300n/120p) = 50 ohm
* Matched source and load at 50 ohm

V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
O1 n1 0 n2 0 MSTRIP
RL n2 0 50

.MODEL MSTRIP LTRA (R=2 L=300n C=120p LEN=0.1)

.TRAN 0.05n 20n

.END
