* HSPICE .jitter [CR .JITTER] on a deterministic clock: an SFFM carrier
* sin(2 pi fc t + m sin(2 pi fs t)), fc = 10.1 MHz, fs = 1 MHz, m = 0.5,
* crosses zero rising where 2 pi fc t + m sin(2 pi fs t) = 2 pi k. Oracle:
* analytic; those roots (Newton to machine precision) for k = 1..202 (101
* modulation phases, twice), minus the least-squares line through them,
* give a time interval error of RMS 5.56739 ns, peak to peak 16.1024 ns
* and period 99.01346 ns (to first order in m fs/fc: RMS m / (2 pi fc
* sqrt 2), period 1/fc). ngspice 44 order: SFFM(VO VA FM MDI FC).
* `.jitter` is an HSPICE card, read in every dialect.
* Expected results: jitter_sffm.expected.json
v1 clk 0 sffm(0 1 1meg 0.5 10.1meg)
r1 clk 0 1k
.tran 0.1n 20.05u
.jitter tran trig v(clk) val=0 td=50n
.end
