# 4. Semiconductor models

Resistors and sources take a value. Diodes and transistors take a *model*:
a named set of parameters declared once with `.model` and shared by every
device that names it.

```text
.model name type(param=value param=value ...)
```

The parentheses are optional. The type says what kind of device the model
is for:

| Type | Device | Element letter |
|---|---|---|
| `D` | diode | `D` |
| `NPN`, `PNP` | bipolar transistor | `Q` |
| `NMOS`, `PMOS` | MOSFET | `M` |
| `NJF`, `PJF` | JFET | `J` |
| `NMF`, `PMF` | MESFET | `Z` |
| `SW`, `CSW` | voltage- and current-controlled switch | `S`, `W` |

Parameters you leave out take the model's defaults.

## Diodes

`D1 anode cathode model`. This half-wave rectifier charges a 100 µF
reservoir through a diode:

```spice
--8<-- "examples/diode_rectifier.sp"
```

```sh
espice diode_rectifier.sp
```

```text
  Measurements for Transient Analysis

vpeak               =  9.228482e+00 at=  5.173860e-03
vmin                =  7.719858e+00 at=  4.317386e-02
Half-wave rectifier: 4 devices
  Transient Analysis: 610 points, 4 variables
```

The output peaks one diode drop below the 10 V input, then sags between
peaks as the load drains the capacitor: about 1.5 V of ripple.

`IS` (saturation current), `N` (emission coefficient), `RS` (series
resistance) and `CJO` (zero-bias junction capacitance) are the parameters
you will set most often.

## Bipolar transistors

`Q1 collector base emitter [substrate] model`. Nested `.dc` sweeps give the
classic output curves: the first source sweeps fastest, once per value of
the second.

```spice
--8<-- "examples/bjt_bias.sp"
```

```sh
espice bjt_bias.sp --rawfile bjt.txt --format=print
```

```text
Operating Point: BJT bias point and output curves
Index	i(vcc)	i(vb)	v(vcc)	v(b)	v(c)
-----	---------------	---------------	---------------	---------------	---------------
0	-5.933074752456546e-4	-3.7802281732556653e-6	5e0	7.000000000000001e-1	4.406692524754345e0
```

At 0.7 V of base drive the collector draws 0.59 mA and the base 3.8 µA,
a current gain of about 157 (BF = 150, raised a little by the Early
effect, VAF = 80 V). The DC sweep has 101 × 3 = 303 points.

## MOSFETs

`M1 drain gate source bulk model W=... L=...`. A MOSFET model's `LEVEL`
picks the equations: `LEVEL=1` is the simple square-law Shichman-Hodges
model, good for learning and hand checks; real processes use BSIM4
(`LEVEL=14` or `54`) or another compact model. Here is a CMOS inverter in
level 1:

```spice
--8<-- "examples/cmos_inverter.sp"
```

```sh
espice cmos_inverter.sp --rawfile inv.raw
```

```text
  Measurements for Transient Analysis

tphl                =  2.818778e-11 targ=  1.078188e-09 trig=  1.050000e-09
CMOS inverter: 5 devices
  DC transfer characteristic: 181 points, 6 variables
  Transient Analysis: 2032 points, 6 variables
```

The `.dc` card gives the voltage transfer curve; `tphl`, the
high-to-low propagation delay into 10 fF, is 28 ps.

## LEVEL

For one element letter, `LEVEL` on the `.model` card picks among the
built-in models. With no `LEVEL`, it is 1.

| Letter | LEVEL | Model |
|---|---|---|
| `M` | 1, 2, 3, 6, 9 | MOS level 1, 2, 3, 6, 9 |
| `M` | 4, 5, 8 / 49 | BSIM1, BSIM2, BSIM3 |
| `M` | 14 / 54 | BSIM4 |
| `M` | 10 / 58, 55, 56 | BSIM-SOI, B3SOI-FD, B3SOI-DD |
| `M` | 68, 73 | HiSIM2, HiSIM-HV |
| `M` | 1040 | PSP 103 |
| `Q` | 1 / 2, 4 / 9, 8 | Gummel-Poon, VBIC 1.3, HICUM/L2 |
| `J` | 1, 2 | JFET, JFET2 |
| `Z` | 1, 2-4, 5, 6 | MESFET, MESA, HFET1, HFET2 |

The [devices page](../using/devices.md) has the full table and what each
model is.

## Exercises

1. In `diode_rectifier.sp`, double C1. What happens to the ripple?
2. Add `.temp 100` to `diode_iv.sp` (chapter 3). Does the diode turn on
   at a lower or higher voltage?
3. In `cmos_inverter.sp`, make the PMOS as wide as the NMOS (`wp={wn}`).
   Where does the switching threshold of the DC curve move?

??? tip "Answers"

    1. The capacitor discharges half as fast, so the ripple roughly halves
       and `vmin` rises.
    2. Lower: IS grows quickly with temperature, so the same current needs
       less forward voltage (about −2 mV per °C).
    3. Down, toward 0 V: the NMOS is now stronger than the PMOS (KP 200µ
       against 80µ), so it pulls the output low at a lower input voltage.
