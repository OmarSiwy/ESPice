# 8. Noise and periodic analyses

The core analyses cover bias, small signals and transients. Two more
families answer questions they cannot: how much noise a circuit adds, and
what a driven circuit settles into once its start-up transient has died.

## Noise

`.noise` computes the noise at an output over a frequency sweep, from
every noisy device (resistor thermal noise, junction shot noise, flicker
noise):

```text
.noise v(out[,ref]) Vinput dec|oct|lin N fstart fstop
```

`Vinput` is the source the noise is referred back to: the input-referred
noise is the output noise divided by the gain from that source.

```spice
--8<-- "examples/noise.sp"
```

```sh
espice noise.sp --rawfile noise.txt --format=print
```

```text
Noise Spectral Density Curves: Resistor divider noise
Index	frequency	onoise_spectrum	inoise_spectrum
-----	---------------	---------------	---------------
0	1e3	9.103863501590959e-9	1.8207727003181918e-8
1	1e4	9.103863501590959e-9	1.8207727003181918e-8
2	1e5	9.103863501590959e-9	1.8207727003181918e-8
```

The two 10k resistors look like 5k from the output, and √(4kT × 5k) at
27 °C is 9.10 nV/√Hz. The divider halves the signal, so the input-referred
noise is twice that. A second plot, `Integrated Noise`, holds the total
noise over the sweep in V rms.

Add a nonzero points-per-summary number at the end of the card
(`.noise v(out) V1 dec 1 1k 100k 1`) to also get each device's
contribution as its own column.

## Periodic steady state

A circuit driven by a periodic source eventually repeats itself. A long
`.tran` gets there by brute force; the periodic analyses solve for the
repeating waveform directly.

`.pss f0 [points]` finds the periodic steady state at fundamental `f0` by
shooting: it searches for the start state that comes back to itself after
one period. `.hb f0 [harmonics]` solves the same problem in the frequency
domain with harmonic balance. `.pac` is the small-signal AC analysis around
the periodic solution: a small input at frequency f shows up at the output
at f and at every f + k·f0 sideband.

```spice
--8<-- "examples/periodic.sp"
```

```sh
espice periodic.sp --rawfile periodic.txt --format=print
```

```text
Diode clipper in periodic steady state: 4 devices
  Periodic Steady State: 257 points, 4 variables
  Periodic AC Analysis: 13 points, 8 variables
  Harmonic Balance: 9 points, 4 variables
```

The PSS plot is one period of every waveform, sampled on 256 steps. The HB
plot lists each harmonic of the fundamental, so the clipping shows up as
numbers:

```text
Harmonic Balance: Diode clipper in periodic steady state
Index	frequency	i(v1)	v(in)	v(out)
-----	---------------	---------------	---------------	---------------
0	0e0	-7.340548706551331e-5	5.787769855067604e-18	-7.340548706551331e-2
1	1e3	1.4676398387175718e-4	1e0	8.643223518291324e-1
2	2e3	9.954476280036665e-5	4.0428049531687237e-17	9.954476280036666e-2
```

The input is a pure 1 V sine. The output has lost some of its fundamental
(0.86 V), grown a −73 mV DC offset and a 2 kHz harmonic of 0.1 V: the
diode clips the positive half-cycles.

The PAC plot has one complex column per sideband, `tf_h-3` to `tf_h3`:
the transfer from the AC source to the output at f + k·f0. `.pac` takes no
output node: it reports the last node the deck names, `out` here.

Related cards: `.pnoise` (noise around the periodic solution), `.pxf`
(transfer from every source), `.hbac`, `.hbnoise` and `.hbxf` (the same on
the harmonic-balance solution), `.qpss` (two incommensurate tones) and
`.hbosc` / `.pss v(node) f` for oscillators. The
[analyses reference](../using/analyses.md) has them all.

## Exercises

1. In `noise.sp`, make R2 1k. Does the output noise go up or down? What
   about the input-referred noise?
2. Raise the sine in `periodic.sp` to 3 V. What happens to the second
   harmonic?
3. Change `.hb 1k 8` to `.hb 1k 2`. Which numbers change, and why is the
   answer less trustworthy?

??? tip "Answers"

    1. The output sees 10k ∥ 1k = 909 Ω, so the output noise falls to
       3.9 nV/√Hz. The gain falls further (to 1/11), so the input-referred
       noise rises to about 42 nV/√Hz.
    2. It grows from 0.10 V to 0.58 V: the diode clips harder, so more of
       the output moves into the harmonics.
    3. Everything moves: DC goes from −73 to −78 mV, the fundamental from
       0.864 to 0.851 V and the second harmonic from 0.100 to 0.125 V. Two
       harmonics cannot represent the clipped waveform, and the error
       leaks into the terms that are kept. Raise the harmonic count until
       the numbers you care about stop changing.
