* HSPICE .ptdnoise [CR .PTDNOISE]: a diode driven by the current
* I(t) = 1m + 0.5m sin(2 pi 1MEG t). Its shot noise 2 q I(t) flows through
* its own conductance I(t)/Vt, so the output noise is memoryless and
* cyclostationary. Oracle: analytic; the density at time t of the period is
* 2 q Vt^2 / I(t), flat in frequency (CJO's 6 GHz pole is far away): at
* t = 250 ns, I = 1.5 mA and 2 q Vt^2 / I = 1.41015e-19 V^2/Hz; at 750 ns,
* I = 0.5 mA and 4.23044e-19 V^2/Hz (Vt = kT/q at 25 degC, HSPICE's default).
* Expected results: ptdnoise_diode.expected.json
i1 0 d sin(1m 0.5m 1meg)
d1 d 0 dm
.model dm d is=1e-14 cjo=1p
.sn tres=10n period=1u
.ptdnoise v(d) time=250n dec 2 1k 100k
.ptdnoise v(d) time=750n tdelta=1n dec 2 1k 100k
.end
