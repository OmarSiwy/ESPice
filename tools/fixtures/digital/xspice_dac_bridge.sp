* XSPICE Mixed-Signal — DAC bridge (digital to analog conversion)
*
* ngspice XSPICE A-devices with () analog ports use automatic adc/dac bridges.
* The d_inverter model has scalar (1-in, 1-out) ports. When analog node names
* are used with () syntax, ngspice auto-inserts adc_bridge on input and
* dac_bridge on output — effectively demonstrating the DAC bridge path.
*
* A PULSE source drives an analog node; d_inverter converts it through the
* digital domain and back to analog, demonstrating the DAC output path.
*
.options noacct
*
* Digital-like source: fast-edge pulse simulating a digital signal
Vsrc src 0 PULSE(0 1.8 1n 0.1n 0.1n 3n 8n)
Rterm src 0 1MEG
*
* d_inverter: analog src -> [auto-adc] -> digital invert -> [auto-dac] -> vout
Adac (src) (vout) DAC_INV
.model DAC_INV d_inverter (rise_delay=0.1n fall_delay=0.1n input_load=0.01p)
*
* Analog load and RC filter on DAC output
Rload vout vfilt 100
Cfilt vfilt 0 10p
Robs vfilt 0 10k
*
.tran 0.5n 40n
.print TRAN V(src) V(vout) V(vfilt)
.END
