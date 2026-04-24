* Diode I-V Forward Characteristic
* Sweep voltage across diode from -1V to 1V

V1 a 0 DC 0
D1 a 0 DMOD

.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u)

.DC V1 -1 1 0.005

.END
