* HSPICE .check, .dout and .biaschk [CR .CHECK, .DOUT, .BIASCHK]: each
* prints its violation count. Oracle: analytic, the PWL corners below.
* GLOBAL_LEVEL (1 0 80% 20%) sets the thresholds to 0.2 and 0.8 V.
* a rises 1n-2n (0.6 ns between thresholds), falls 5n-5.5n (0.3 ns);
* clk rises at 3.05 ns, d rises at 2.55 ns and falls at 3.55 ns (threshold
* midpoints). n dips below -0.5 V for 2.1 ns, then for 0.15 ns.
* rise (0.5n 1n) a: 0; fall: 1; slew: 1. setup (clk rise 1n rise) d: 1
* (2.55 within 1 ns before 3.05); hold (clk rise 1n fall) d: 1 (3.55);
* edge (clk rise 0.2n 1n fall) d: 0. irdrop (-0.5 1n) n: 1 (the 0.15 ns
* dip passes). dout: d is low at 4 ns, expected 1: 1. biaschk
* v(a)-v(d) > 0.9: from 1.9 to 2.51 ns and from 3.59 to 5.05 ns: 2.
* Expected results: checks.expected.json
va a 0 pwl(0 0 1n 0 2n 1 5n 1 5.5n 0)
vclk clk 0 pwl(0 0 3n 0 3.1n 1)
vd d 0 pwl(0 0 2.5n 0 2.6n 1 3.5n 1 3.6n 0)
vn n 0 pwl(0 0 6n 0 6.1n -1 8.1n -1 8.2n 0 9n 0 9.05n -1 9.15n -1 9.2n 0)
.check global_level (1 0 80% 20%)
.check rise (0.5n 1n) a
.check fall (0.5n 1n) a
.check slew (0.5n 1n) a
.check setup (clk rise 1n rise) d
.check hold (clk rise 1n fall) d
.check edge (clk rise 0.2n 1n fall) d
.check irdrop (-0.5 1n) n
.dout d 0.5 (2n 0 3n 1 4n 1)
.biaschk 'v(a)-v(d)' max=0.9
.tran 10p 10n
.end
