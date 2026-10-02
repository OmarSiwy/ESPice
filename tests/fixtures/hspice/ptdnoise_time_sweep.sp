* HSPICE .ptdnoise with a TIME sweep [CR .PTDNOISE]: the ptdnoise_diode
* circuit, I(t) = 1m + 0.5m sin(2 pi 1MEG t) through a diode, strobed at
* TIME = LIN 3 250n 750n, one plot per time. Oracle: analytic; the density
* at time t of the period is 2 q Vt^2 / I(t), flat in frequency: I = 1.5,
* 1 and 0.5 mA at 250, 500 and 750 ns (Vt = kT/q at 25 degC). The
* 7-sideband conversion matrix leaves 0.15 % at 500 ns, where I(t) is
* steepest.
* Expected results: ptdnoise_time_sweep.expected.json
i1 0 d sin(1m 0.5m 1meg)
d1 d 0 dm
.model dm d is=1e-14 cjo=1p
.sn tres=10n period=1u
.ptdnoise v(d) time=lin 3 250n 750n dec 2 1k 100k
.end
