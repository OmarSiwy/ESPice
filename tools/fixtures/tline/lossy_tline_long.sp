* Long Lossy Transmission Line with Significant Attenuation
*
* Uses LTRA (Lossy Transmission Line) model
* R=50 ohm/unit, L=500nH/unit, C=200pF/unit, length=2 units
* Significant resistive loss causes amplitude decay and pulse rounding
* Matched 50 ohm source and load

V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
O1 n1 0 n2 0 LMOD
RL n2 0 50

.MODEL LMOD LTRA (R=50 L=500n C=200p LEN=2)

.TRAN 0.1n 50n

.END
