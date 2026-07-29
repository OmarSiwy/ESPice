# MOSRA: HSPICE MOSFET reliability (aging)

HSPICE MOSRA [SA Ch.29; CR .MOSRA, .APPENDMODEL] ages MOSFETs in two
phases. A fresh transient measures how hard each device is stressed. The
stress is then extrapolated to a lifetime and written back as degraded
parameters for the aged simulation. ESPice implements level 1 (the
built-in power law) for HCI and BTI. This page covers what ESPice reads,
its equations, and how they diverge from HSPICE (hspice-comparison E6).

No copy of the MOSRA chapter was available when this was written, so the
card syntax follows the manual as remembered. **The level 1 parameter
names and equations below are ESPice's own and unconfirmed against the
manual.** Treat a deck written for HSPICE's level 1 model as needing its
model card translated.

## 1. What a deck can say

```
.model nra mosra level=1 tit0=1e-4 titfd=0.5 tn=0.25 hci0=2e-6 hcin=0.5 hcimu=0.1
.appendmodel nra mosra n3 nmos          $ MOSRA model nra ages every M card of model n3
.mosra reltotaltime=1e8 relstep=5e7 simmode=2 degf=0.05
.tran 1n 10n                             $ the stress transient
```

| `.mosra` key | Meaning | Default |
|---|---|---|
| `RelTotalTime` | last reliability time, seconds (required) | |
| `RelStartTime`, `RelStep` | with `RelStep > 0`, aged runs at `RelStartTime + k·RelStep` below `RelTotalTime`, then at `RelTotalTime` (non-positive times skipped) | 0, 0 |
| `SimMode` | 0: fresh runs and the degradation table only; 2: fresh runs, then every analysis again at each reliability time | 2 (unconfirmed) |
| `RelMode` | 0: HCI and BTI; 1: HCI only; 2: BTI only | 0 |
| `AgingStart`, `AgingStop` | stress window within the transient, seconds | 0, end |
| `HciThreshold`, `NbtiThreshold` | Vgs (V, polarity-corrected; not Vgs - Vth) at or below which a mechanism sees no stress | 0, 0 |
| `DegF` | the |ΔVth| that ends a device's life; adds `life(m)` columns | none |

`.appendmodel src MOSRA dst NMOS|PMOS` binds MOSRA model `src` to every M
card of model `dst`. A bin card `dst.N` matches `dst`.

Refused, each with an error naming it: `.mosrapi` (HSPICE's C API for
custom aging models), `.mosraprint`, `.mosra_subckt_pin_volt`, `SimMode`
1 (reads a `.radeg0` file from an earlier run) and 3, `DEC`, `LIN`,
`AgingPeriod`, `AgingWidth`, `AgingInst`, `Integmod`, `Xpolatemod`,
`Tsample`, `DegFF`, `MosraLife`, `RelEndTime` and any other key. MOSRA together with
`.step`, `.alter`, an analysis sweep or `OPTIMIZE=` is refused, as is a deck
with no `.tran`, and a MOSRA model with a level other than 1.

## 2. Level 1 model (ESPice's choice, unconfirmed)

Each mechanism k of a device sees, while stressed,

$$A_k(t) = a_{0,k}\,\exp(fd_k\,v_k(t) - td_k/T)$$

with T the device temperature in kelvin during the stress run: the
instance's own `temp` when its card gives one, else the circuit
temperature (`.temp` or `.options temp`; without either, TNOM, 25 °C
under HSPICE) plus the
instance's `dtemp`, as mos3 and ngspice compute it. A model without a
`dtemp` parameter (all aging models but mos3) runs at the circuit
temperature. T is the same for every mechanism of a device, and

| k | a0, fd, td, n | v | stressed when |
|---|---|---|---|
| BTI (NBTI for PMOS, PBTI for NMOS) | `TIT0`, `TITFD`, `TITTD`, `TN` (0.25) | Vgs | Vgs > NbtiThreshold |
| HCI | `HCI0`, `HCIFD`, `HCITD`, `HCIN` (0.5) | Vds | Vgs > HciThreshold and Vds > 0 |

Voltages are taken with the device's polarity (negated for PMOS), and the
lower terminal acts as the source, so a reversed Vds swaps drain and source.

The degradation at reliability time t is the quasi-static power law

$$\Delta V_{th,k}(t) = \Big(t\cdot\overline{A_k^{1/n_k}}\Big)^{n_k}$$

where the average is the trapezoidal integral over the transient's samples
inside the aging window, divided by the window's length. Under constant
stress this is exactly $A_k t^{n_k}$; under periodic stress it is the usual
equivalent-time sum. The aged run writes the instance parameters

- `delvto` = the device's own `delvto` ± (ΔVth_HCI + ΔVth_BTI), the shift
  positive for NMOS and negative for PMOS, so |Vth| always grows;
- `mulu0` = the device's own `mulu0` / (1 + HCIMU·ΔVth_HCI + TITMU·ΔVth_BTI).

The degradation table holds the shift and the mobility factor, not the
resulting parameter values.

`DegF` lifetime: the t at which ΔVth_HCI(t) + ΔVth_BTI(t) = DegF, by
bisection on log10 t over [1e-30, 1e30] s; `inf` when it is never reached.

Only device models with a `delvto` parameter can age: bsim3 (LEVEL 8/49),
bsim4 (LEVEL 14/54), BSIM-SOI (LEVEL 10/58), mos3 and mos9. Only bsim3
also has `mulu0`, so `TITMU` and `HCIMU` are refused on the others. Every
other MOSFET model is refused.

## 3. Flow

1. `frontend/netlist.zig` reads `.mosra` and `.appendmodel`.
   `frontend/mosra.zig` binds the M cards, finds each one's `delvto` and
   `mulu0` `ParamRef` indices, fresh values and drain, gate and source
   rows, and plans one
   `core.Variants` row per reliability time. `Fanout.global` then runs every
   card fresh and once per row, so the aged plots read
   `Operating Point (reltime=100000000)`.
2. `Problem.age` (in `espice.zig`, run once before any query, beside
   `optimize`) runs the deck's first `.tran` in a session of its own,
   with the bound devices' drain, gate and source as its only outputs.
   `analysis/post/mosra.zig age` integrates the stress, fills the rows'
   values and builds the degradation table.
3. The table is published first, as the plot `MOSRA Degradation`: one row
   per reliability time, columns `reltime`, then `delvto(m)` (the ΔVth
   shift), `mulu0(m)` (the mobility factor) and with DegF `life(m)` per
   device. It stands in for HSPICE's `.radeg`
   file.

The stress transient repeats the fresh `.tran`, which costs one extra
transient. This is marked `ponytail:` in `Problem.age`.

## 4. Divergences from HSPICE

- The level 1 equations and parameter names (§2) are ESPice's, not
  confirmed against the manual.
- The degradation table is a plot in the output file, not a separate
  `.radeg` text file, and SimMode 1 cannot read one back.
- Aging applies through `delvto` and `mulu0` only. HSPICE's level 1 also
  degrades other parameters in some versions; that is not modeled.
- The default SimMode of 2 is unconfirmed.
- The aging window snaps to the transient's own samples inside
  [AgingStart, AgingStop]; it is not interpolated to the window edges.
- Bulk voltage plays no part in either mechanism.

## 5. Verification

- Unit: `src/analysis/post/mosra.zig` test `age: constant stress is A t^n,
  and DegF inverts it`.
- Fixtures under `tests/fixtures/mosra/` (analytic):
  - `nmos_dc_stress.sp`: a bsim3 NMOS held at Vgs = 1.2 V, Vds = 1.5 V;
    the table's `delvto`, `mulu0` and `life` against the closed form.
  - `nmos_dtemp_arrhenius.sp`: three mos3 NMOS at one stress, at
    dtemp 0 and 50 and at an explicit temp=100. Each delvto against
    1e-2·exp(-3000/T)·(1e8)^0.25, so the m2/m1 ratio is the Arrhenius
    factor exp(3000·(1/298.15 - 1/348.15)).
  - `nmos_aged_vth.sp`: the same NMOS held at a fixed drain current by a
    servo loop, BTI only. The aged `.op` gate voltage is the fresh one
    plus 1e-4·(1e8)^0.25 = 0.01 V. With UA = UB = UC = 0 (so mobility does
    not depend on Vth) BSIM3 lands within 2e-6 V of that; with the
    original UA it lands 1.4e-4 V short, since BSIM3's mobility degradation
    reads (Vgsteff + 2Vth).
