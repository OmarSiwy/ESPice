* Verilog toggle flip-flop clocked by an analog PWL: the A2D threshold band
* (vth = 2.5 V, vhys = 1 V: rising edges at 3 V, falling at 2 V) rejects a
* 5 V -> 2.2 V -> 5 V glitch that a bare 2.5 V threshold would clock twice
* Expected results: verilog_tff_hysteresis.expected.json
* Oracle (analytic): clk rises through 3 V at 6 ns (0 -> 5 V over 10 ns) and
* at 28 ns (22 ns -> 32 ns); the dip to 2.2 V at 14 ns never leaves the band.
* q toggles 0 -> 1 at 6 ns and 1 -> 0 at 28 ns, each a 1 ns linear ramp
* (trise = tfall = 1 ns) of the Thevenin driver (rout = 1 ohm) into 1 kohm,
* so the high level is 5 * 1000/1001 = 4.995005 V. Mid-ramp samples allow
* 5 mV: the device starts a ramp at the accepted step's end, at most ttol =
* 0.5 ps (half the 1 ps tick) after the crossing, i.e. 2.5 mV of ramp.
* With vhys = 0 q would fall at 14.43 ns and read 0 V at 16 ns.
.hdl "verilog_tff_hysteresis.assets/v_tff.v"
Vclk clk 0 PWL(0 0 10n 5 14n 2.2 18n 5 22n 0 32n 5 42n 0)
N1 clk q tffm
.model tffm v_tff vhys=1
Rl q 0 1k
.tran 0.1n 45n
.end
