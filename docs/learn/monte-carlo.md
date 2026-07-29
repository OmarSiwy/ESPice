# 9. Monte Carlo

Real components are not their nominal values. Monte Carlo analysis draws
random values for the uncertain parts, runs the circuit once per draw
(a "trial"), and shows you the spread of the results. ESPice has two ways
to do it.

## `.mc`: vary everything

`.mc N [sigma]` solves the DC operating point N times. In each trial every
nonzero primary value (a resistance, a source's DC value, ...) is drawn
from a Gaussian with relative standard deviation `sigma` (5 % when left
out).

```spice
--8<-- "examples/monte_carlo.sp"
```

```sh
espice monte_carlo.sp --rawfile mc.txt --format=print
```

```text
Monte Carlo: Divider spread with Monte Carlo
Index	run	i(v1)	v(in)	v(out)
-----	---------------	---------------	---------------	---------------
0	0e0	-5.019314544505537e-4	1.008343975468438e0	5.089972819330152e-1
1	1e0	-4.992573771362285e-4	1.0046445486122524e0	5.006259192731827e-1
2	2e0	-4.93595057803361e-4	9.862268274323318e-1	4.905860481796562e-1
```

One row per trial. V1 varies too: `v(in)` is not exactly 1 V.

## `agauss` and `MONTE=`: vary what you choose

For control over which values vary, write the distribution into the deck
and ask an analysis to run as a Monte Carlo sweep with `MONTE=n`.

| Function | Draws |
|---|---|
| `agauss(nom, var, n)` | Gaussian around `nom`; `var` is the absolute spread at `n` sigma |
| `gauss(nom, rvar, n)` | the same with a relative spread |
| `aunif(nom, var)` | uniform in nom ± var |
| `unif(nom, rvar)` | uniform with a relative spread |

Outside a Monte Carlo run these functions return `nom`, so the same deck
also simulates the nominal circuit.

```text
.dc MONTE=n                  n trials of the operating point
.tran ... SWEEP MONTE=n      n transients (also .ac, .dc with a sweep)
.option seed=N               a fixed seed: the same trials every run
```

Here only the two resistors vary, each by 1 % (30 Ω at 3 sigma), and V1
stays at exactly 1 V:

```spice
--8<-- "examples/monte_agauss.sp"
```

```text
Monte Carlo: Divider spread with agauss and a Monte Carlo DC
Index	run	i(v1)	v(in)	v(out)
-----	---------------	---------------	---------------	---------------
0	1e0	-4.98898735103262e-4	1e0	4.9498315376777796e-1
1	2e0	-4.97205754614453e-4	1e0	4.945092576673322e-1
2	3e0	-5.003152460377415e-4	1e0	4.957336298692346e-1
```

Over the 200 trials `v(out)` has a sigma of 3.8 mV; two independent 1 %
resistors predict 0.5 V × 0.01 / √2 = 3.5 mV.

A transient run with a measurement gets statistics over the trials:

```spice
--8<-- "examples/monte_tran.sp"
```

```sh
espice monte_tran.sp
```

ESPice prints `tc` once for the nominal run and once per trial, then the
statistics (the tail of the output):

```text
tc                  =   6.81503e-07
tc                  =   6.87338e-07
  Monte Carlo statistics over 50 trials
mean(tc) = 6.894056e-07
sigma(tc) = 2.106016e-08
min(tc) = 6.229492e-07
max(tc) = 7.412147e-07
```

The delay is R C ln 2, so a 3 % sigma on R gives a 3 % sigma on the delay:
693 ns × 0.03 = 20.8 ns, and the 50 trials measure 21.1 ns.

An `agauss` in a `.param` is drawn once per trial and shared by every
element that uses the parameter; an `agauss` written directly on an element
is drawn for that element alone. That is the difference between global
(process) and local (mismatch) variation. HSPICE-style `DEV` and `LOT`
tolerances on `.model` parameters, and the `.variation` block, work too;
see the [language reference](../using/reference.md#statistics).

## Mismatch without trials

For the DC offset that mismatch causes, `.dcmatch v(out)` computes the
1-sigma spread directly from sensitivities, with no random trials. The
[analyses reference](../using/analyses.md#dcmatch) covers it, with
`.acmatch` and `.dcsens`.

## Exercises

1. Run `monte_carlo.sp` with sigma 0.02. By how much should the spread of
   `v(out)` grow?
2. Change `monte_tran.sp` so C varies by 10 % as well, as a separate
   parameter. What sigma do you expect for `tc`?
3. Remove `.option seed=3` and run `monte_tran.sp` twice. Are the
   statistics the same?

??? tip "Answers"

    1. Twice as much: the spread is linear in sigma for small variations.
    2. Independent relative spreads add in quadrature:
       √(0.03² + 0.1²) = 10.4 %, about 72 ns.
    3. Each run without a seed is still reproducible: ESPice uses a fixed
       default seed. Change the seed to get a different set of trials.
