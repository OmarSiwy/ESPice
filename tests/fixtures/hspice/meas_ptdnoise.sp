* HSPICE .measure PTDNOISE [CR .MEASURE] over hspice/ptdnoise_diode's
* first card: the density 2 q Vt^2 / I(t) at t = 250 ns, I = 1.5 mA, flat
* in frequency. Oracle: analytic, 1.41015e-19 V^2/Hz.
* Expected results: meas_ptdnoise.expected.json
i1 0 d sin(1m 0.5m 1meg)
d1 d 0 dm
.model dm d is=1e-14 cjo=1p
.sn tres=10n period=1u
.ptdnoise v(d) time=250n dec 2 1k 100k
.measure ptdnoise n10k find ptdnoise_density at=10k
.measure ptdnoise navg avg ptdnoise_density from=1k to=100k
.end
