* XSPICE Mixed-Signal — ADC bridge (analog to digital conversion)
*
* ngspice XSPICE A-devices with () analog ports use automatic adc/dac bridges.
* The d_inverter model has scalar (1-in, 1-out) ports compatible with the
* analog () port syntax. ngspice auto-inserts adc_bridge on the input and
* dac_bridge on the output when analog node names are used with ().
*
* This demonstrates analog -> digital domain -> analog round-trip:
*   V(in) [analog] -> auto-adc -> d_inverter -> auto-dac -> V(vdigital) [analog]
*
.options noacct
*
* Analog input: slowly ramping voltage crosses logic threshold (~0.9V = Vdd/2)
Vin in 0 PULSE(0 1.8 2n 8n 8n 10n 40n)
Rterm in 0 1MEG
*
* ADC + digital processing + DAC via single A-device with analog () ports.
* d_inverter: scalar input, scalar output — auto adc/dac inserted by ngspice.
* The output is the digital-domain inverted version of the input.
Ainv (in) (vdigital) INVMOD
.model INVMOD d_inverter (rise_delay=0.1n fall_delay=0.1n input_load=0.01p)
*
Robs vdigital 0 10k
*
.tran 0.5n 40n
.print TRAN V(in) V(vdigital)
.END
