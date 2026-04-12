* Diode Voltage Doubler (Villard/Greinacher)
*
* Two diodes + two caps driven by AC source
* AC source: SIN 0 5 1MEG (5V peak, 1MHz)
* Expected output: ~2*Vpeak - 2*Vd ~ 8.6V DC

.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* AC input source
V1 in 0 SIN(0 5 1MEG)

* First stage: clamp circuit
* C1 AC-couples, D1 clamps negative peak to ground
C1 in mid 100n
D1 0 mid DMOD

* Second stage: peak detector
* D2 charges C2 to the clamped peak
D2 mid out DMOD
C2 out 0 100n

* Load resistor
R_load out 0 10k

.TRAN 0.1u 20u

.END
