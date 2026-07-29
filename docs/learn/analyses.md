# 3. The four core analyses

Almost everything in circuit simulation starts from four analyses:

| Card | Answers | Independent variable |
|---|---|---|
| `.op` | the DC bias of every node | none (one point) |
| `.dc` | the DC bias as a source or parameter sweeps | the swept value |
| `.ac` | the small-signal frequency response around the bias | frequency |
| `.tran` | the large-signal response over time | time |

A deck may hold any number of analysis cards; ESPice runs them all and
writes one result (a "plot") per card.

## An RC low-pass, three ways

```spice
--8<-- "examples/rc_lowpass.sp"
```

```sh
espice rc_lowpass.sp --rawfile rc.txt --format=print
```

```text
RC low-pass filter: 3 devices
  Operating Point: 1 points, 3 variables
  AC Analysis: 41 points, 4 variables
  Transient Analysis: 519 points, 4 variables
```

### `.op`: the operating point

`.op` solves the circuit with capacitors open and inductors shorted. V1's
DC value is 0, so every node sits at 0 V here. The operating point is also
where `.ac` linearizes the circuit and where `.tran` starts, so ESPice
computes it for those analyses even when the deck has no `.op` card.

### `.ac`: frequency response

```text
.ac dec 10 10 100k
```

sweeps from 10 Hz to 100 kHz with 10 points per decade. `oct N` gives N
points per octave and `lin N` N points in total. The sources' `AC` values
drive the circuit; here V1 has `AC 1`, so `v(out)` *is* the transfer
function. AC results are complex, so each column has a real and an
imaginary part:

```text
AC Analysis: RC low-pass filter
Index	frequency	(imag)	i(v1)	(imag)	v(in)	(imag)	v(out)	(imag)
-----	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------
0	1e1	0e0	-9.979542742416352e-8	-9.989267655685869e-6	1e0	0e0	9.999002045725759e-1	-9.98926765568587e-3
1	1.2589254117941673e1	0e0	-1.5815586205860516e-7	-1.2575008897885423e-5	1e0	0e0	9.998418441379414e-1	-1.2575008897885423e-2
```

At 10 Hz the output is 0.9999 − 0.00999j: almost all of the input, with
a little phase lag.

### `.tran`: time response

```text
.tran 10u 5m
```

runs from 0 to 5 ms. The first number is the print step: it sets the
default maximum time step and the default rise and fall times of
`PULSE` sources. ESPice picks its own steps from the local truncation
error, so the point count (519 here) is not 5 ms / 10 µs. The full
syntax is `.tran tstep tstop [tstart [tmax]] [uic]`: points before
`tstart` are simulated but not saved, and `tmax` caps the step.

## `.dc`: sweeping a source

```spice
--8<-- "examples/diode_iv.sp"
```

```text
.dc V1 0 0.8 0.01
```

steps V1 from 0 to 0.8 V by 10 mV and solves the operating point at each
step. The first column of the result is the sweep variable:

```text
DC transfer characteristic: Diode I-V curve with a DC sweep
Index	v(v-sweep)	i(v1)	v(a)
-----	---------------	---------------	---------------
0	0e0	0e0	0e0
1	1e-2	-1.386624089968383e-14	1e-2
2	2e-2	-3.166792969038269e-14	2e-2
```

The sweep target can be a voltage or current source, a resistor (its
resistance), or `TEMP` for the temperature. Add a second source and
range to nest two sweeps; the [next chapter](models.md) does that for
BJT output curves.

## Initial conditions

By default a transient starts from the operating point. To start it from
a state you choose, give node voltages with `.ic` and add `uic` to the
`.tran` card: the transient then skips the operating point and starts from
the `.ic` values, with every other node at zero. (Without `uic`, ESPice
does not use `.ic` at all; ngspice would hold those nodes during the
operating point instead.)

```spice
--8<-- "examples/rc_ic.sp"
```

```text
  Measurements for Transient Analysis

vtau                =  1.839401e+00
Capacitor discharge from an initial condition: 2 devices
  Transient Analysis: 508 points, 2 variables
```

After one time constant (RC = 1 ms) the capacitor holds 5 V × e⁻¹ = 1.84 V.
The `.meas` line is a measurement; [chapter 7](measure.md) covers them.

`.nodeset` looks like `.ic` but only gives the operating-point solver a
starting guess. Use it to help a circuit with several stable states (a
latch, a ring oscillator) converge to the one you want.

## Exercises

1. Add `.meas ac f3db WHEN vdb(out)=-3` to `rc_lowpass.sp`. Is the
   answer close to 1/(2πRC)?
2. Change the `.ac` card to `lin 100 10 100k`. Why does the low-frequency
   end of the curve now look coarse?
3. Change `.tran 10u 5m` to `.tran 10u 5m 4m`. How many points does the
   transient keep?
4. In `diode_iv.sp`, sweep from −1 V to 0.8 V. What does the diode
   current do below 0 V?

??? tip "Answers"

    1. ESPice prints `f3db = 9.98589e+02`, 999 Hz; 1/(2π × 1k × 159n) = 1001 Hz.
    2. 100 linear points from 10 Hz to 100 kHz are about 1 kHz apart, so
       the first decade has a single point. Use `dec` for responses that
       span decades.
    3. 102: only the points from 4 ms to 5 ms are saved. The simulation
       still runs from 0.
    4. It flattens out at about −1 pA: the diode blocks. That is more than
       IS (10 fA) because SPICE puts a tiny conductance, `gmin` = 1e-12 S,
       across every junction to help convergence, and at −1 V it carries
       1 pA.
