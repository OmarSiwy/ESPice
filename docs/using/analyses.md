# Analyses

One section per analysis card. Each gives the syntax, what it computes,
the result it writes (plot name and columns) and a one-line example. Node
voltages come out as `v(node)`, branch currents as `i(source)`. Frequency
sweeps everywhere take the same grid:

```text
dec N fstart fstop    N points per decade
oct N fstart fstop    N points per octave
lin N fstart fstop    N points in total
poi N f1 f2 ... fN    the listed frequencies (HSPICE; ascending)
```

ESPice adds the prerequisites an analysis needs (an `.ac` needs an
operating point) and shares them between analyses. `espice --plan deck.sp`
shows the graph.

## DC

### `.op` { #op }

```text
.op
.op [format] t1 t2 ...        HSPICE: operating points at times
```

The DC operating point: capacitors open, inductors shorted. Plot
`Operating Point`, one row: every node voltage and every voltage-source
current. With times, ESPice runs the `.tran` card up to each time and
publishes `Operating Point (time=t)`. `format` (`all`, `brief`, `current`,
`debug`, `none`, `voltage`) is accepted and has no effect.

If Newton's method does not converge directly, ESPice steps gmin and then
the sources down, as ngspice does.

```text
.op
```

### `.dc` { #dc }

```text
.dc src start stop step [src2 start2 stop2 step2]
.dc src LIN|DEC|OCT N start stop
.dc src POI N v1 v2 ...
.dc src START=a STOP=b STEP=c
.dc DATA=name | MONTE=n
```

Sweeps a source's DC value, a resistor's resistance or `TEMP`, solving
the operating point at each point. A second source and range nest an
outer sweep (the first varies fastest). Plot `DC transfer characteristic`;
the first column, `v(v-sweep)`, is the swept value.

```text
.dc VIN 0 1.8 0.01 VDD 1.6 2.0 0.2
```

### `.tf` { #tf }

```text
.tf v(out[,ref]) src
.tf i(Vmeasure) src
```

The DC small-signal transfer function from a V or I source to an output
voltage or current, plus the input and output resistances. Plot
`Transfer Function`: `transfer_function`, `input_resistance`,
`output_resistance`.

```text
.tf v(out) VIN
```

### `.sens` { #sens }

```text
.sens v(out[,ref])
```

DC sensitivity of the output to every device parameter, from one adjoint
solve. Plot `Sensitivity Analysis`, one column per instance parameter,
named like ngspice's (`v(r1)`, `v(vcc)`, `v(vin:acmag)`, ...).

```text
.sens v(out)
```

### `.dcmatch` { #dcmatch }

```text
.dcmatch v(out[,ref])
```

The 1-sigma DC output spread from device mismatch, from sensitivities
rather than random trials. Sigmas come from the deck's `.variation` block
when it has one, otherwise from the models' Pelgrom data, otherwise unit
variance. Plot `DC Mismatch`: `total_3sigma` and one `<card>@<param>`
column per contribution.

```text
.dcmatch v(out)
```

### `.dcsens`, `.acmatch` { #acmatch }

```text
.dcsens v(out) [FILE= PERTURBATION= INTERVAL= THRESHOLD= GROUPBYDEVICE=]
.acmatch v(out) [THRESHOLD= FILE= INTERVAL= VIRTUAL_SENSITIVITY= SENS_THRESHOLD=]
```

HSPICE's DC sensitivity to each variation group (`DC Sensitivity`) and
the AC mismatch spread over the deck's `.ac` sweep (`AC Mismatch`:
`acm_mag`, `acm_phase`, `acm_re`, `acm_im` and per-group columns). The
listing keywords are checked and have no effect: every group is
published.

### `.dcxf`, `.acxf`, `.dcinc` { #dcxf }

```text
.dcxf v(out[,ref]) [tf]
.dcxf i(Vmeasure) [tf]
.acxf v(out) dec|oct|lin N fstart fstop [tf]
.dcinc
```

`.dcxf` gives the DC transfer function from *every* independent source to
one output, with each source's input impedance and admittance (plot `DC
Transfer Functions`: `tf(v1)`, `zin(v1)`, `yin(v1)`, ...). `tf` skips the
impedances and needs only one solve. `.acxf` does the same over
frequency (`AC Transfer Functions`). `.dcinc` is the incremental DC
response to every source's `AC` magnitude (`DC Incremental Analysis`).

### `.temp` { #temp }

```text
.temp t                 one value: the circuit temperature, not an analysis
.temp tstart tstop tstep    ngspice: a temperature sweep
.temp t1 t2 t3 ...      HSPICE dialect: every analysis at each temperature
```

The three-number form solves the operating point at each temperature in
°C (plot `Temperature Sweep`).

```text
.temp -40 125 5
```

### `.mc` { #mc }

```text
.mc N [sigma]
```

N Monte Carlo trials of the DC operating point. Each trial draws every
nonzero primary value from a Gaussian with relative sigma `sigma`
(default 0.05). Plot `Monte Carlo`, one row per trial, first column `run`.
For controlled variation, use `agauss` and `MONTE=` instead
([chapter 9](../learn/monte-carlo.md)).

```text
.mc 1000 0.01
```

## Small signal

### `.ac` { #ac }

```text
.ac dec|oct|lin N fstart fstop
.ac POI N f1 ... fN
```

The circuit linearized at its operating point and driven by the sources'
`AC` values. Plot `AC Analysis`, complex, first column `frequency`.
Frequency points are solved in SIMD batches over one factorization
pattern.

```text
.ac dec 20 1 1g
```

### `.noise` { #noise }

```text
.noise v(out[,ref]) [src] dec|oct|lin N fstart fstop [pts]
.noise v(out) src [inter]          HSPICE: over the .ac sweep
.acphasenoise v(out) vin [interval] carrier=f [LIST...=]
```

Output noise and input-referred noise over frequency. `src` is a V or I
source, the input reference. A nonzero `pts` (or HSPICE `inter`) adds each
device's contribution as a column. Two plots: `Noise Spectral Density
Curves` (`onoise_spectrum`, `inoise_spectrum` in V/√Hz, and
`onoise_<inst>_<generator>`, `onoise_<inst>` with contributions) and
`Integrated Noise` (`v(onoise_total)`, `v(inoise_total)` in V rms).
`.acphasenoise` is the same solve read as phase noise (`AC Phase Noise
Analysis`, `phnoise`). `.sample` folds the spectrum for sampled systems.

```text
.noise v(out) VIN dec 10 10 10meg 1
```

### `.pz` { #pz }

```text
.pz in+ in- out+ out- vol|cur pol|zer|pz
.pz v(out[,ref]) src          HSPICE: driven at the source's nodes, both
.pz                           the circuit's natural poles
```

Poles and zeros of the transfer function from the input port to the
output port, in rad/s. `vol` is a voltage transfer (the deck must have a
voltage source across the input port), `cur` a current injection. Plot
`Pole-Zero Analysis`, one row of complex columns `pole(1)`, `pole(2)`,
..., `zero(1)`, ....

```text
.pz in 0 out 0 vol pz
```

### `.disto` { #disto }

```text
.disto dec|oct|lin N fstart fstop [f2/f1]
```

Small-signal distortion by Volterra series, ngspice style. Mark the drive
with `DISTOF1 mag [phase]` on a V card; for intermodulation give the
`f2/f1` ratio and a `DISTOF2` source. Plots `DISTORTION - 2nd harmonic`
and `DISTORTION - 3rd harmonic`, or with two tones `DISTORTION - IM: f1+f2`,
`IM: f1-f2` and `IM: 2f1-f2`, plus a `Distortion Analysis` summary
(`v1_mag`, `v2_mag`, `hd2`, ...).

```text
.disto dec 10 1k 100k
```

### `.sp`, `.lin`, `.net` { #sp }

```text
.sp dec|oct|lin N fstart fstop
.lin [SPARCALC=1] [NOISECALC=] [GDCALC=] [FORMAT=touchstone] [FILENAME=] [MIXEDMODE2PORT=dd|cc|sd|...]
.net v(out) src [RIN= ROUT=]     .net src [rin]
```

S-parameters between the deck's ports. A port is a V card with
`portnum n z0 Z` (HSPICE: a `P` card, `port=n z0=Z`). Plot `SP Analysis`
with complex `v(S_i_j)` columns. `.lin` and `.net` (HSPICE) run over the
`.ac` sweep; `.lin` publishes `S(i,j)`, `Y(i,j)` and more, and with a
3-node `P` card mixed-mode parameters. Write Touchstone or CITIfile with
`--format`.

```spice
--8<-- "examples/two_port.sp"
```

```sh
espice two_port.sp --format=touchstone --rawfile lc.s2p
```

### `.stb` { #stb }

```text
.stb Vprobe dec|oct|lin N fstart fstop
```

Loop gain through a 0 V probe source placed in the loop. Plot `Stability
Analysis`, `loop_gain`.

### `.lstb` { #lstb }

```text
.lstb mode=single|diff|comm vsource=Vp[,Vn] [localgnd=n] [dec|oct|lin N f1 f2]
```

Loop stability by double injection at one probe (or a differential pair
for `diff` and `comm`), over the `.ac` sweep unless the card gives its
own. Plots `Loop Stability Analysis` (`loop_gain`, `loop_gain_forward`,
`loop_gain_reverse`, `y11` ... `y22`) and `Loop Stability Margins`
(`gain_margin`, `phase_crossover_freq`, `phase_margin`, `unity_gain_freq`,
`loop_gain_minifreq`), which `.meas lstb pm phase_margin` reads.

```text
.lstb mode=single vsource=Vprobe
```

## Transient

### `.tran` { #tran }

```text
.tran tstep tstop [tstart [tmax]] [uic]
.tran s1 t1 s2 t2 ... [START=t] [uic]     HSPICE dialect: segments
```

The time-domain response. `tstep` sets the default PULSE edges and, with
`tstop/50`, the default step cap (`tmax`, or `.option delmax`). Points
before `tstart` are computed but not saved. `uic` starts from the `.ic`
values instead of the operating point. Trapezoidal integration by
default; `.option method=gear` selects Gear. Plot `Transient Analysis`,
first column `time`.

```text
.tran 1n 10u
```

### `.four` { #four }

```text
.four f0 v(out) [v(out2) ...] [nharm]
```

Fourier coefficients of the last period of the transient, from DC to
`nharm` harmonics (default 9). One plot per output, `Fourier Analysis
(THD = x %)` (`Fourier Analysis v(out) (THD = ...)` for several outputs):
`harmonic`, `frequency`, `magnitude`, `phase_deg`.

```text
.four 1k v(out)
```

### `.fft` { #fft }

```text
.fft v(out[,ref]) [START= STOP= NP= FORMAT=norm|unorm WINDOW= ALFA= FREQ= FMIN= FMAX=]
```

HSPICE FFT of a `.tran` output, resampled on NP points (rounded up to a
power of two) and windowed (`rect`, `bart`, `hann`, `hamm`, `black`,
`harris`, `gauss`, `kaiser`). Plot `FFT Analysis v(out)`: `frequency` and
one complex column. `.meas fft` reads THD, SNR, SNDR, ENOB and SFDR from it.

```text
.fft v(out) NP=1024 WINDOW=hann
```

### `.trannoise` { #trannoise }

```text
.trannoise tstep tstop
.trannoise v(out) [METHOD=mc|sde] [SEED=] [SAMPLES=] [FMIN=] [FMAX=] [SCALE=] [TIME=]
```

A transient with every device's noise sources sampled (also spelled
`.tran_noise`). The HSPICE form runs on the deck's `.tran` card;
`SAMPLES=n` runs n independent noise transients, and `METHOD=sde`
carries the noise covariance instead of sampling and publishes `onoise`.
Plot `Transient Noise Analysis`.

```text
.trannoise v(out) samples=3 seed=1
```

### `.envelope` { #envelope }

```text
.envelope tcarrier tstop
```

Envelope-following transient (also `.envlp`): full carrier periods
integrated, the envelope stepped across them. Plot `Envelope Analysis`
with per-output `peak(...)` and `rms(...)` columns.

```text
.envelope 1m 5m
```

### `.matex` { #matex }

```text
.matex tstep tstop
```

Transient by matrix exponential (R-MATEX, Krylov). Plot `MATEX Transient
Analysis`.

```text
.matex 1u 2m
```

## Periodic steady state

### `.pss` { #pss }

```text
.pss f0 [points]
.pss v(osc) f0guess [points [settle]]      autonomous oscillator
.sn TRES=t PERIOD=T  |  .sn TONE=f [NHARMS=n]     HSPICE shooting Newton
.snosc v(osc) f0guess [points]
```

Periodic steady state by shooting Newton at fundamental `f0` (default 256
points). With an oscillator node, `f0` is a first guess and the period is
solved for. Plot `Periodic Steady State`: one period of every waveform,
first column `time`.

```text
.pss 1k 256
```

### `.pac`, `.pxf` { #pac }

```text
.pac f0 dec|oct|lin N fstart fstop
.pxf f0 dec|oct|lin N fstart fstop
.snac dec|oct|lin N f1 f2          .snxf v(out) dec|oct|lin N f1 f2
```

Periodic AC: the small-signal response around the PSS orbit, driven by the
sources' `AC` values. Plot `Periodic AC Analysis`, complex columns
`tf_h-3` ... `tf_h3`: the transfer to each sideband f + k·f0. `.pxf` is
the periodic transfer function from every source (`Periodic Transfer
Function Analysis`, `pxf_h<k>(out)`). Neither card names an output: they
use the last node the deck names. The HSPICE `.snac`/`.snxf` run at the
`.sn` card's tone.

```text
.pac 1k dec 4 10 10k
```

### `.pnoise` { #pnoise }

```text
.pnoise v(out[,ref]) src dec|oct|lin N fstart fstop f0 [sidebands]
.snnoise v(out) src dec|oct|lin N f1 f2
.ptdnoise v(out) TIME=t|sweep [TDELTA=] dec|oct|lin N f1 f2
```

Noise of a periodically driven circuit, folded from up to `sidebands`
(default 7) sidebands. Plot `Periodic Noise Analysis`, `pnoise_density`.
`.ptdnoise` is the time-dependent noise at strobe times (`Periodic
Time-Dependent Noise Analysis (time=t)`, `ptdnoise_density`).

```text
.pnoise v(out) Vin dec 3 10 10k 1k 3
```

### `.hb` { #hb }

```text
.hb f0 [harmonics]
.hb v(osc) f0guess [harmonics]                 autonomous (also .hbosc)
.hb TONES=f1 f2 ... NHARMS=n1 n2 ... [INTMODMAX=m] [SUBHARMS=k] [SS_TONE=i]
```

Harmonic balance (default 8 harmonics). The multitone `TONES=` form gives
quasi-periodic solutions and reports phasors. Plot `Harmonic Balance`, first
column `frequency`, one row per harmonic.

```text
.hb 1k 8
```

### `.hbac`, `.hbxf`, `.hbnoise` { #hbac }

```text
.hbac dec|oct|lin N f1 f2 [f0 [K]]
.hbxf v(out) dec|oct|lin N f1 f2 [f0 [K]]
.hbnoise v(out[,ref]) [Vsrc] dec|oct|lin N f1 f2 [f0 [K [M]]]
```

The `.pac`, `.pxf` and `.pnoise` sweeps on the harmonic-balance orbit
instead of the shooting one. Without `f0` they take the deck's `.hb`
tone. Plots `Harmonic Balance AC Analysis`, `Harmonic Balance Transfer
Function Analysis`, `Harmonic Balance Noise Analysis` (`hbnoise_density`).

### `.hblin` { #hblin }

```text
.hblin dec|oct|lin N f1 f2 [NOISECALC=0|1] [FILENAME= DATAFORMAT=]
```

S-parameters of the deck's ports around the `.hb` solution. Plot
`Harmonic Balance LIN Analysis`, `S(i,j)` columns.

### `.phasenoise` { #phasenoise }

```text
.phasenoise v(out) dec|oct|lin N f1 f2 [f0 [K]] [METHOD=0|1|2] [CARRIERINDEX=k]
```

Oscillator phase noise about the autonomous HB solution of the deck's
`.hbosc` (or the tone given here). Plot `Phase Noise Analysis`, `phnoise`.

```text
.phasenoise v(t) dec 2 1k 1meg
```

### `.qpss` { #qpss }

```text
.qpss f1 f2 [k1 [k2]]
```

Two-tone quasi-periodic steady state, keeping `k1` and `k2` harmonics of
each tone (default 5). Plot `Quasi-Periodic Steady State`.

```text
.qpss 1000 1414.2 2 2
```

## Runs over variants

These wrap other analyses rather than being analyses themselves; see the
[language reference](reference.md#statistics):

- `.step` reruns every analysis per point; plots are named
  `<plot> (name=value)`.
- `.alter` blocks rerun the deck with changes: `<plot> (alter=n)`.
- `SWEEP DATA=`, `SWEEP MONTE=` and `SWEEP OPTIMIZE=` on one card:
  `<plot> (monte=n)`, `(optimize=...)`.
- An HSPICE `.temp` list: `<plot> (temp=t)`.
- `.mosra` adds `MOSRA Degradation` (aging per device) and reruns the
  aged circuit.
