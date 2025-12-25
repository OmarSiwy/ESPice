* BJT differential amplifier, resistive tail to a negative rail, DC sweep of Vin.
* Both bases have a DC return path; moderate beta keeps Newton well-behaved.
VCC vcc 0 DC 5
VEE vee 0 DC -5
Vin inp 0 DC 0
RB2 inn 0 10k
RCp vcc cp 4k
RCn vcc cn 4k
RT tail vee 4.7k
Q1 cp inp tail QN
Q2 cn inn tail QN
.model QN NPN(IS=1e-16 BF=100)
.dc Vin -0.1 0.1 0.005
.end
