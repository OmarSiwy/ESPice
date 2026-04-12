* Simplified Synchronous Buck Converter
*
* High-side and low-side voltage-controlled switches
* VIN=12V, target VOUT~5V (duty cycle ~42%)
* L=10uH, C=10uF, R_load=1 ohm
* PWM at 500kHz

.MODEL SW SW (VT=2.5 VH=0.5 RON=1 ROFF=1MEG)

* Input supply
VIN vin 0 DC 12

* PWM control signal for high-side (duty ~42% for 5V out)
* Period = 2us, on-time = 0.84us
V_PWM pwm 0 PULSE(0 5 0 10n 10n 0.83u 2u)

* Complementary control for low-side (inverted PWM)
V_PWMN pwmn 0 PULSE(5 0 0 10n 10n 0.83u 2u)

* High-side switch: connects VIN to switch node when PWM is high
S_HS vin sw pwm 0 SW

* Low-side switch: connects switch node to GND when PWM is low
S_LS sw 0 pwmn 0 SW

* LC output filter
L1 sw out 10u
C1 out 0 10u IC=5
R_load out 0 1

* ESR on output cap (realistic)
* (modeled as series R with C — simplified by lumping into R_load path)

.IC V(out)=5

.TRAN 0.1u 200u UIC

.END
