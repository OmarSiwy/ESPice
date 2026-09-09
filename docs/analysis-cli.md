# Analysis directives

CLI directives below create the named analysis job. Malformed requests fail
with an engine error and exit status 1; they never become an implicit operating
point. A deck containing no analysis still runs an implicit `.op`.

These are ESPice's implemented positional forms. They do not imply compatibility
with every ngspice option. Numbers accept SPICE suffixes. `v(node)` accepts named
or numeric nodes. Output nodes and voltage sources must exist.

| Directive | Arguments |
|---|---|
| `.op` | none |
| `.dc` | `source start stop step [source2 start2 stop2 step2]`; `source2` may be `temp` |
| `.tran` | `step stop [0 [maxstep]] [uic]` |
| `.ac` | `dec points_per_decade first last` |
| `.noise` | `v(out) voltage_source dec points_per_decade first last` |
| `.tf` | `v(out) voltage_source` |
| `.sens`, `.dcmatch` | `v(out)` |
| `.four` | `fundamental_frequency v(out) [harmonics]`; runs its own transient |
| `.disto` | `dec points_per_decade first last` |
| `.pz` | none; poles of the circuit pencil only |
| `.pss` | `fundamental_frequency [samples_per_period]` |
| `.hb` | `fundamental_frequency [harmonics]` |
| `.qpss` | `frequency1 frequency2 [harmonics1 [harmonics2]]` |
| `.pac`, `.pxf` | `lo_frequency dec points_per_decade first last` |
| `.pnoise` | `v(out) voltage_source dec points_per_decade first last fundamental_frequency [sidebands]` |
| `.sp` | `dec points_per_decade first last` or `lin total_points first last` |
| `.envelope` | `carrier_period stop` |
| `.matex`, `.trannoise` | `step stop` |
| `.mc` | `trials [relative_variation]`; deterministic default seed |
| `.temp` | `first_celsius last_celsius step_celsius`; single `celsius` configures deck temperature |

Aliases: `.envlp`, `.montecarlo`, `.tran_noise`. Frequency and time arguments
must be positive. Counts must be positive integers within the module's count
type. Sweeps must advance toward their endpoint; temperature sweeps require
positive steps. PNOISE sidebands may be zero;
the maximum is 31 for its default 64 time samples.

## Capability gaps exposed by fixture coverage

- `.stb` fails with `UnsupportedStabilityAnalysis`. The library currently
  computes probe admittance, which is not dimensionless loop return ratio.
  The existing STB golden fixture checks rejection; it is not an accuracy pass.
  Use ngspice's loop measurement workflow until a return-ratio solver lands.
- Conventional `.pz in+ in- out+ out- vol pz` requests fail with
  `UnsupportedPoleZeroArguments`. Transfer zeros and input/output selection
  are absent. Bare `.pz` retains the existing pole solver.
- AC-family LIN/OCT sweeps fail with `UnsupportedFrequencySweep`; only SP
  supports LIN. Nonzero transient output start fails with
  `UnsupportedTransientStart`.
- Mixed voltage/current-source DC sweeps selecting a current source fail with
  `UnsupportedMixedCurrentSweep`: the library's batch-local source index
  otherwise aliases a voltage source. Voltage-source sweeps and current-only
  decks retain the existing implementation.
- PSS now interprets its first argument as frequency, matching the existing
  fixture intent. The previous implementation interpreted `.pss 1k` as a
  1000-second period. Historical extra PSS fixture arguments had no Options
  equivalents and are rejected; use the documented frequency/sample form.
- HB/QPSS currently inject a fixed unit current at the drive node rather than
  deriving all excitations from netlist source spectra. Current-only HB/QPSS
  decks are rejected because no drive node is available. Their finite-output
  fixtures are dispatch coverage, not ngspice accuracy evidence. Unconverged
  solves now fail with `HbDidNotConverge`/`QpssDidNotConverge` and emit no plot.
- SP currently uses the library's single default 50-ohm drive port. Netlist
  `portnum`/`z0` source annotations do not populate a multiport list.
- Noise results are output noise PSD. The named input source is checked for
  existence, but input-referred noise is not emitted.

`benchmark/fixtures/golden` contains one fixture per analysis ID, including
explicit unsupported-capability coverage. `benchmark/check_fixtures.py` checks
requested plots and finite payloads separately from analytical and ngspice
comparisons. Finite samples alone establish no accuracy claim.
