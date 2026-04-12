* Large Voltage Swing — Diode Limiter Stress Test
*
* Source with very large amplitude (100V peak)
* Diode limiter clips both polarities
* Tests convergence with huge excursions and breakdown

V1 in 0 SIN(0 100 1MEG)
R1 in mid 1k
D1 mid out DMOD
D2 0 mid DMOD

.MODEL DMOD D (IS=1e-14 N=1 BV=50)

R2 out 0 10k
C1 out 0 1n

.TRAN 10n 10u

.END
