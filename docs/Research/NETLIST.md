# BigOSpice SPICE Netlist Language Reference

This is a quick reference for all SPICE directives, analysis commands, output
cards, waveform types, and expression syntax supported by BigOSpice. Directives are
case-insensitive. Lines beginning with `*` are comments. The first line of every
netlist is always the title line (even if it begins with `*`).

Line continuation: a `+` at the start of a line joins it to the preceding line.

---

## Table of Contents

1. [Structure](#structure)
2. [Model Card](#model-card)
3. [Subcircuits](#subcircuits)
4. [Parameters and Functions](#parameters-and-functions)
5. [Analysis Cards](#analysis-cards)
6. [Control Cards](#control-cards)
7. [Output Cards](#output-cards)
8. [Source Waveforms](#source-waveforms)
9. [Expression Syntax](#expression-syntax)
10. [.control Block](#control-block)
11. [Numeric Suffixes](#numeric-suffixes)

---

## Structure

```
<title line — always consumed, even if blank>
* comments start with *
<element lines>
<dot directives>
.END
```

---

## Model Card

```
.MODEL  mname  type  [(param=val ...)]
```

`type` selects the device physics. Recognized types:

| Type       | Device                                |
|------------|---------------------------------------|
| `R`, `RES` | Resistor                              |
| `C`, `CAP` | Capacitor                             |
| `D`        | Diode                                 |
| `NPN`      | NPN BJT (Gummel-Poon or VBIC)        |
| `PNP`      | PNP BJT (Gummel-Poon or VBIC)        |
| `NMOS`     | N-channel MOSFET (LEVEL selects model)|
| `PMOS`     | P-channel MOSFET                      |
| `NJF`      | N-channel JFET                        |
| `PJF`      | P-channel JFET                        |
| `NMF`      | N-channel MESFET (Curtice)            |
| `PMF`      | P-channel MESFET                      |
| `SW`       | Voltage-controlled switch             |
| `CSW`      | Current-controlled switch             |
| `LTRA`     | Lossy transmission line               |
| `URC`      | Uniform RC line                       |

Parameters are `key=value` pairs, separated by spaces. Parentheses are optional.
Long model cards may be continued with `+`.

```spice
.MODEL nfet NMOS (LEVEL=14 TOXE=1.8e-9 VTH0=0.42 U0=450
+                 VSAT=9e4 RDSW=150)
```

---

## Subcircuits

### Definition

```
.SUBCKT  name  port1  port2  ...  [param=default ...]
* element lines
* nested .SUBCKT / .ENDS allowed
.ENDS  [name]
```

Default parameter values are evaluated once when the subcircuit is instantiated.
Parameters defined in the header override outer `.PARAM` values inside the body.

### Instantiation

```
Xname  node1  node2  ...  subckt_name  [param=val ...]
```

Node count must match the `.SUBCKT` port list exactly. All internal node names
are mangled to `Xname.nodename` to prevent collisions.

```spice
.SUBCKT INV  in  out  vdd  gnd  W=1u  L=100n
M1  out  in  vdd  vdd  PMOS  W={W*2}  L={L}
M2  out  in  gnd  gnd  NMOS  W={W}    L={L}
.ENDS INV

X1  a  b  power  0  INV  W=2u
```

---

## Parameters and Functions

### .PARAM

```
.PARAM  name=value  [name2=value2 ...]
.PARAM  name={expr}
```

Defines a scalar parameter usable as `{name}` in any numeric field.
Multiple assignments on the same line and multiple `.PARAM` lines are all merged.

```spice
.PARAM  VDD=3.3  CLOAD=10f  RDRV={VDD/5m}
```

### .GLOBAL_PARAM

```
.GLOBAL_PARAM  name=value  ...
```

Like `.PARAM` but visible inside all subcircuit scopes without being passed as
an instance parameter. Xyce extension.

### .FUNC

```
.FUNC  name(arg1, arg2, ...)  {body_expr}
```

Defines a user function callable from any `{expr}` field.

```spice
.FUNC  vt(t)  {8.617e-5 * (t + 273.15)}
.FUNC  gm(id, n)  {id / (n * vt(27))}
```

### .DISTRIBUTION

```
.DISTRIBUTION  name  type  [(params)]
```

Defines a custom statistical distribution for Monte Carlo analysis.
`type` is one of `UNIFORM`, `GAUSSIAN`, `LOGNORM`, `BIMODAL`. HSPICE extension.

### .STEP

```
.STEP  [LIN]  param  start  stop  step
.STEP  DEC    param  start  stop  points_per_decade
.STEP  OCT    param  start  stop  points_per_octave
.STEP  LIST   param  v1  v2  v3  ...
.STEP  device.param  start  stop  step
```

Sweeps a `.PARAM` value or a device parameter over the listed analysis.

```spice
.STEP RLOAD LIST 1k 2k 5k 10k
.STEP DEC VDD 1.0 3.6 10
```

### .IF / .ELSEIF / .ELSE / .ENDIF

```
.IF (condition)
  ... conditional elements or directives ...
.ELSEIF (condition)
  ...
.ELSE
  ...
.ENDIF
```

Condition is a boolean expression: `param > value`, `param == value`, etc.
`.IFDEF name` / `.IFNDEF name` test whether `name` is defined.

---

## Analysis Cards

### .OP — DC Operating Point

```
.OP
```

Computes DC operating point. No sweep. Results available via `.PRINT DC` or
inspected in a `.control` block.

### .DC — DC Sweep

```
.DC  src_or_param  start  stop  step  [src2 start2 stop2 step2]
```

Sweeps a voltage/current source or `.PARAM` value. Nested sweep with second
source gives a 2D sweep.

```spice
.DC  VIN  0  5  0.1
.DC  VGS  0  2  0.01  VDS  0  3  0.1
```

### .AC — AC Sweep

```
.AC  DEC|OCT|LIN  points  fstart  fstop
```

Small-signal AC analysis. Circuit linearized at DC operating point.

| Sweep type | Description                         |
|------------|-------------------------------------|
| `DEC`      | Points per decade (log frequency)   |
| `OCT`      | Points per octave (log frequency)   |
| `LIN`      | Total points (linear frequency)     |

```spice
.AC  DEC  20  1  1GIG
```

### .TRAN — Transient

```
.TRAN  tstep  tstop  [tstart  [tmax]]  [UIC]
```

| Parameter | Description                                  |
|-----------|----------------------------------------------|
| tstep     | Suggested internal time step [s]             |
| tstop     | Simulation end time [s]                      |
| tstart    | Output start time [s] (default 0)            |
| tmax      | Maximum time step [s] (default tstep)        |
| UIC       | Use initial conditions (skip DC OP solve)    |

```spice
.TRAN  1n  1u  0  5n
```

### .HB — Harmonic Balance

```
.HB  fund_freq  [nharms=N]  [tones=f1,f2,...]
```

Steady-state frequency-domain analysis for driven nonlinear circuits.
Single-tone and two-tone supported; N-tone via `tones=` list.

```spice
.HB  1GIG  nharms=7
.HB  tones=900MEG,1100MEG  nharms=5
```

### .PSS — Periodic Steady State

```
.PSS  fund_freq  [period=val]  [harms=N]
```

Shooting-method periodic steady state. Related to HB but time-domain-based.

```spice
.PSS  100MEG
```

### .NOISE — Noise Analysis

```
.NOISE  V(out[,ref])  Vsrc  sweep_type  points  fstart  fstop  [ptspersum]
```

| Parameter  | Description                                    |
|------------|------------------------------------------------|
| V(out,ref) | Output node (and optional reference node)      |
| Vsrc       | Input noise reference source name              |
| sweep_type | `DEC`, `OCT`, or `LIN`                         |
| points     | Points per decade/octave or total              |
| fstart     | Start frequency [Hz]                           |
| fstop      | Stop frequency [Hz]                            |
| ptspersum  | Summary print interval (optional)              |

```spice
.NOISE  V(out)  Vin  DEC  10  1k  100MEG
```

### .DISTO — Small-Signal Distortion

```
.DISTO  f1  [numf2  [f2overf1  [fstart  [fstop]]]]
```

Volterra-series small-signal distortion. `f1` is the fundamental. `numf2=1`
enables IM analysis at `f2 = f1 * f2overf1`.

```spice
.DISTO  1MEG  1  0.9
```

### .SP — S-Parameter Analysis

```
.SP  DEC|OCT|LIN  points  fstart  fstop
```

Two-port S-parameter analysis driven by `PORT` elements.

```spice
.SP  DEC  20  100MEG  10GIG
```

### .PZ — Pole-Zero Analysis

```
.PZ  in+  in-  out+  out-  VOL|CUR  POL|ZER|PZ
```

Finds poles, zeros, or both for the specified transfer function.

```spice
.PZ  in  0  out  0  VOL  PZ
```

### .TF — Transfer Function

```
.TF  outvar  insrc
```

Computes DC small-signal transfer function, input resistance, and output
resistance.

```spice
.TF  V(out)  Vin
```

### .SENS — Sensitivity Analysis

```
.SENS  outvar  [DC|AC|TRAN]
```

Computes sensitivity of `outvar` to every element parameter.

```spice
.SENS  V(out)  DC
```

### .FOUR — Fourier Analysis

```
.FOUR  fund_freq  v_or_i_spec  [v_or_i_spec ...]
```

Post-processes a `.TRAN` result: computes Fourier coefficients and THD.
`fund_freq` must match the transient stimulus.

```spice
.FOUR  1MEG  V(out)  I(R1)
```

### .SAMPLING — Monte Carlo / Quasi-MC

```
.SAMPLING  [N=count]  [SEED=val]  [METHOD=LHS|MC|QUASI]
```

Statistical sweep over device tolerances defined with `DEV=` and `LOT=`
modifiers in `.MODEL` cards. Xyce extension.

```spice
.SAMPLING  N=200  METHOD=LHS
```

---

## Control Cards

### .OPTIONS

```
.OPTIONS  [category]  key=val  [key2=val2 ...]
```

Sets simulator options. `category` is optional (Xyce style: `NONLIN`, `LINSOL`,
`TIMEINT`). Common keys:

| Key        | Description                                      | Default |
|------------|--------------------------------------------------|---------|
| TNOM       | Nominal temperature [°C]                         | 27      |
| TEMP       | Circuit temperature [°C]                         | 27      |
| ABSTOL     | Absolute current tolerance [A]                   | 1e-12   |
| RELTOL     | Relative tolerance                               | 1e-3    |
| VNTOL      | Absolute voltage tolerance [V]                   | 1e-6    |
| ITL1       | DC iteration limit                               | 100     |
| ITL2       | DC transfer curve iteration limit                | 50      |
| ITL4       | Transient timestep iteration limit               | 10      |
| METHOD     | Integration method (`GEAR`, `TRAP`)              | GEAR    |
| MAXORD     | Maximum BDF order (1–5)                          | 2       |
| SCALE      | Global element scale factor                      | 1       |
| GMIN       | Minimum branch conductance [S]                   | 1e-12   |
| PIVTOL     | Minimum pivot tolerance for LU                   | 1e-13   |
| LINSOL     | Linear solver (`DENSE`, `KLU`)                   | DENSE   |

```spice
.OPTIONS  RELTOL=1e-4  ABSTOL=1e-15  METHOD=GEAR  MAXORD=2
```

### .GLOBAL

```
.GLOBAL  node1  [node2 ...]
```

Declares nodes as global so they are visible inside subcircuits without being
passed as ports.

```spice
.GLOBAL  vdd  gnd
```

### .CONNECT

```
.CONNECT  node1  node2
```

Short-circuits two named nets at the top-level netlist (W.6, in progress).

### .INCLUDE

```
.INCLUDE  "filename"
.INCLUDE  filename
```

Inserts the contents of `filename` inline. Paths are relative to the including
file. Cycle detection prevents infinite recursion.

### .LIB

```
.LIB  "filename"  section
.LIB  section_name          (definition block header)
.ENDL  [section_name]       (definition block end)
```

Pulls in a named section from a library file or defines a named block inline.

---

## Output Cards

### .PRINT

```
.PRINT  DC|AC|TRAN|NOISE  [FORMAT=fmt]  var1  [var2 ...]
```

Prints simulation results to stdout or a file. Variable specifiers:

| Specifier   | Meaning                                           |
|-------------|---------------------------------------------------|
| `V(n)`      | Node voltage                                      |
| `V(n1,n2)`  | Differential voltage                              |
| `I(Vxxx)`   | Current through voltage source `Vxxx`             |
| `I(R1)`     | Current through element `R1`                      |
| `VM(n)`     | Magnitude (AC)                                    |
| `VP(n)`     | Phase [degrees] (AC)                              |
| `VR(n)`     | Real part (AC)                                    |
| `VI(n)`     | Imaginary part (AC)                               |
| `VDB(n)`    | 20*log10(VM) — dB (AC)                            |
| `INOISE`    | Input-referred noise (NOISE analysis)             |
| `ONOISE`    | Output noise (NOISE analysis)                     |

```spice
.PRINT  TRAN  V(out)  I(Vdd)
.PRINT  AC    VDB(out)  VP(out)
```

### .PROBE

```
.PROBE  [DC|AC|TRAN]  var1  [var2 ...]
```

Alias for `.PRINT`. Saves waveforms for post-processing.

### .SAVE

```
.SAVE  var1  [var2 ...]
.SAVE  ALL
```

Selects which waveforms are retained in memory for `.MEASURE` evaluation and
post-processing. `ALL` saves every node voltage and branch current.

### .MEASURE / .MEAS

```
.MEASURE  DC|AC|TRAN  name  TRIG ...  TARG ...
.MEASURE  DC|AC|TRAN  name  FIND  var  [WHEN ...]
.MEASURE  DC|AC|TRAN  name  AVG|MIN|MAX|RMS  var  [FROM=t1 TO=t2]
.MEASURE  DC|AC|TRAN  name  DERIV  var  [AT=t]
.MEASURE  DC|AC|TRAN  name  INTEGRAL  var  [FROM=t1 TO=t2]
.MEASURE  TRAN        name  RISE|FALL|CROSS  var  [VAL=v] [TD=t] [COUNT=n]
```

Post-simulation measurement. Results stored in the output and accessible in
`.control` blocks via `meas_result` variables.

```spice
.MEAS  TRAN  trise  TRIG  V(in)   VAL=0.5  RISE=1
+             TARG  V(out) VAL=0.5  RISE=1
.MEAS  TRAN  vmax   MAX   V(out)
```

### .EXTRACT

```
.EXTRACT  DC|AC|TRAN  label=expr  [label2=expr2 ...]
```

HSPICE-style post-simulation extraction. Evaluates measurement functions
(`ymax()`, `xmin()`, `at()`, `cross()`, etc.) on waveform data. (W.5)

---

## Source Waveforms

Used as the waveform specification in `V` and `I` source instance lines.
Both parenthesised and bare positional forms are accepted:
`PULSE(0 5 1u 1n 1n 10u 20u)` or `PULSE 0 5 1u 1n 1n 10u 20u`.

### PULSE

```
PULSE(v1  v2  td  tr  tf  pw  per  [cycles])
```

| Param   | Description                        | Default |
|---------|------------------------------------|---------|
| v1      | Initial value                      | —       |
| v2      | Pulsed value                       | —       |
| td      | Delay time [s]                     | 0       |
| tr      | Rise time [s]                      | tstep   |
| tf      | Fall time [s]                      | tstep   |
| pw      | Pulse width [s]                    | tstop   |
| per     | Period [s]                         | tstop   |
| cycles  | Number of cycles (0 = infinite)    | 0       |

### SIN

```
SIN(vo  va  freq  [td  [theta  [phase]]])
```

```
v(t) = vo + va * exp(-theta * (t - td)) * sin(2π * freq * (t - td) + phase)
```

| Param | Description                        | Default |
|-------|------------------------------------|---------|
| vo    | Offset voltage                     | —       |
| va    | Amplitude                          | —       |
| freq  | Frequency [Hz]                     | —       |
| td    | Delay [s]                          | 0       |
| theta | Damping factor [1/s]               | 0       |
| phase | Phase offset [degrees]             | 0       |

### EXP

```
EXP(v1  v2  td1  tau1  td2  tau2)
```

Double-exponential waveform.

| Param | Description                        |
|-------|------------------------------------|
| v1    | Initial value                      |
| v2    | Pulsed value                       |
| td1   | Rise delay [s]                     |
| tau1  | Rise time constant [s]             |
| td2   | Fall delay [s]                     |
| tau2  | Fall time constant [s]             |

### PWL

```
PWL(t0 v0  t1 v1  t2 v2  ...)
PWL FILE="filename"  [R=offset]
```

Piecewise-linear waveform. Time-voltage pairs in ascending time order.
`FILE=` loads pairs from a two-column CSV. `R=` adds a repeat offset.

### SFFM

```
SFFM(vo  va  fc  mdi  fs)
```

Single-frequency FM signal.
```
v(t) = vo + va * sin(2π*fc*t + mdi * sin(2π*fs*t))
```

| Param | Description                        |
|-------|------------------------------------|
| vo    | Offset                             |
| va    | Amplitude                          |
| fc    | Carrier frequency [Hz]             |
| mdi   | Modulation index                   |
| fs    | Signal (modulating) frequency [Hz] |

### AM

```
AM(vo  va  fc  fm  [td])
```

Amplitude modulation.
```
v(t) = va * (vo + sin(2π*fm*(t-td))) * sin(2π*fc*(t-td))
```

| Param | Description                        |
|-------|------------------------------------|
| vo    | Modulation offset                  |
| va    | Carrier amplitude                  |
| fc    | Carrier frequency [Hz]             |
| fm    | Modulating frequency [Hz]          |
| td    | Delay [s]                          |

### TRNOISE

```
TRNOISE(na  nt  nalpha  namp  [td])
```

Transient noise source (white + 1/f noise).

| Param  | Description                        |
|--------|------------------------------------|
| na     | RMS amplitude of white noise [V/√Hz or A/√Hz] |
| nt     | Time step for noise [s]            |
| nalpha | 1/f exponent (0 = white only)      |
| namp   | 1/f amplitude                      |
| td     | Delay before noise starts [s]      |

### TRRANDOM

```
TRRANDOM(type  ts  td  param1  [param2])
```

Periodic random waveform.

| type | Distribution | param1  | param2      |
|------|--------------|---------|-------------|
| 1    | Uniform      | range   | —           |
| 2    | Gaussian     | sigma   | mean        |
| 3    | Exponential  | mean    | —           |
| 4    | Poisson      | lambda  | —           |

---

## Expression Syntax

Expressions appear inside `{...}` braces in any numeric field.

### Operators

| Operator | Description              | Precedence |
|----------|--------------------------|------------|
| `**`, `^`| Power                    | highest    |
| unary `-`| Negation                 |            |
| `*`, `/` | Multiply, divide         |            |
| `+`, `-` | Add, subtract            |            |
| `<`, `>`, `<=`, `>=` | Comparisons (return 0 or 1) | |
| `==`, `!=`| Equality                |            |
| `&&`     | Logical AND              |            |
| `\|\|`   | Logical OR               | lowest     |

Ternary: `cond ? val_true : val_false`

### Built-in Functions

| Function      | Description                            |
|---------------|----------------------------------------|
| `abs(x)`      | Absolute value                         |
| `sqrt(x)`     | Square root                            |
| `exp(x)`      | Exponential e^x                        |
| `log(x)`      | Natural logarithm                      |
| `log10(x)`    | Base-10 logarithm                      |
| `sin(x)`      | Sine (radians)                         |
| `cos(x)`      | Cosine (radians)                       |
| `tan(x)`      | Tangent (radians)                      |
| `asin(x)`     | Inverse sine                           |
| `acos(x)`     | Inverse cosine                         |
| `atan(x)`     | Inverse tangent                        |
| `atan2(y,x)`  | Two-argument inverse tangent           |
| `sinh(x)`     | Hyperbolic sine                        |
| `cosh(x)`     | Hyperbolic cosine                      |
| `tanh(x)`     | Hyperbolic tangent                     |
| `floor(x)`    | Floor                                  |
| `ceil(x)`     | Ceiling                                |
| `round(x)`    | Round to nearest integer               |
| `min(a,b)`    | Minimum                                |
| `max(a,b)`    | Maximum                                |
| `pow(a,b)`    | Power a^b                              |
| `int(x)`      | Truncate to integer                    |
| `sgn(x)`      | Sign: -1, 0, or +1                     |
| `if(c,t,f)`   | Conditional (alias for ternary)        |
| `V(n)`        | Node voltage (in B/E/G source exprs)   |
| `V(n1,n2)`    | Differential voltage                   |
| `I(Vsrc)`     | Branch current                         |

### Constants

| Name   | Value                    |
|--------|--------------------------|
| `pi`   | 3.14159265358979…        |
| `e`    | 2.71828182845904…        |

### Simulation Variables (in B-source and behavioral expressions)

| Variable    | Meaning                           |
|-------------|-----------------------------------|
| `time`      | Current simulation time [s]       |
| `temper`    | Circuit temperature [°C]          |
| `frequency` | Current AC frequency [Hz]         |

### Examples

```spice
.PARAM  Vdd=3.3  Rval={Vdd / 1m}
R1  out  0  {Rval * 2}
B1  out  0  V={tanh(V(in)/25m) * 100m}
C1  node  0  {if(fast_mode, 10f, 100f)}
```

---

## .control Block

```
.control
  <control statements>
.endc
```

An interactive scripting shell block embedded in the netlist. Evaluated after
the netlist is loaded.

### Common Control Commands

| Command               | Description                                      |
|-----------------------|--------------------------------------------------|
| `run`                 | Execute pending analysis                         |
| `op`                  | Run DC operating point                           |
| `dc src start stop step` | Run DC sweep                                |
| `ac dec pts f1 f2`    | Run AC sweep                                     |
| `tran tstep tstop`    | Run transient                                    |
| `print var [var ...]` | Print variable values                            |
| `plot var [var ...]`  | Plot waveforms (interactive mode)                |
| `write filename`      | Write all vectors to a raw file                  |
| `wrdata filename var` | Write a specific vector as ASCII                 |
| `set key=val`         | Set a simulator option                           |
| `let name=expr`       | Assign a derived waveform or scalar              |
| `meas tran name ...`  | Post-simulation measurement                      |
| `foreach var list`    | Loop over a list                                 |
| `end`                 | End a `foreach` loop                             |
| `if (cond)`           | Conditional block                                |
| `else` / `end`        | Else branch / end conditional                    |
| `echo string`         | Print string to console                          |
| `quit`                | Exit simulator                                   |

```spice
.control
  tran 1n 1u
  meas tran tfall TRIG V(out) VAL=2.5 FALL=1 TARG V(out) VAL=0.5 FALL=1
  echo Fall time = $tfall
  wrdata results.dat v(out)
.endc
```

---

## Numeric Suffixes

SPICE suffix letters (case-insensitive) applied to numeric literals:

| Suffix | Multiplier | Value     |
|--------|------------|-----------|
| `T`    | tera       | 1e12      |
| `G`    | giga       | 1e9       |
| `MEG`  | mega       | 1e6       |
| `K`    | kilo       | 1e3       |
| `M`    | milli      | 1e-3      |
| `U`    | micro      | 1e-6      |
| `N`    | nano       | 1e-9      |
| `P`    | pico       | 1e-12     |
| `F`    | femto      | 1e-15     |
| `A`    | atto       | 1e-18     |

Note: `M` means milli (1e-3), not mega. Use `MEG` for mega.
Standard scientific notation (`1e6`, `1.5e-9`) is always accepted.
