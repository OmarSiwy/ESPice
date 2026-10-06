# Output

A run produces three kinds of output:

| Where | What |
|---|---|
| stderr | one summary line per deck and per result (`AC Analysis: 41 points, 4 variables`), warnings and errors |
| stdout | `.meas` results, Monte Carlo statistics, and `--plan` / `--print-dag` graphs |
| `--rawfile FILE` | the results themselves, in the `--format` you choose |

Without `--rawfile`, results stay in memory and nothing is written.

## Results, plots and columns

Each analysis produces one result, called a plot as in ngspice. A plot has
a name (`Transient Analysis`, `AC Analysis (rval=2000)`), a list of
variables (columns) and points (rows). The first column is the
independent variable (`time`, `frequency`, `v(v-sweep)`, `run`) except in
single-point plots such as `Operating Point`. AC-type plots are complex.

Column names follow ngspice: `v(node)` for node voltages, `i(vname)` for
the current through a voltage source (and inductors, B and E sources),
`v(x1.node)` inside subcircuit instance `x1`, and `v(n1#node)` for an
internal node of a Verilog-A instance `n1`.

## Formats

| `--format` | Aliases | File | Several plots |
|---|---|---|---|
| `binary` (default) | `raw` | ngspice binary raw | appended to one file |
| `ascii` | | ngspice ASCII raw | appended to one file |
| `print` | `text` | tab-separated text table per plot | appended to one file |
| `csv` | | comma-separated, one header row | `FILE`, `FILE.2`, `FILE.3`, ... |
| `touchstone` | `snp`, `s2p` | Touchstone `.sNp` | numbered files |
| `citi` | `citifile` | CITIfile | numbered files |
| `psf` | | Cadence PSF ASCII | numbered files |
| `fsdb` | | a minimal FSDB-style binary container | numbered files |
| `sst2` | `hspice` | HSPICE SST2-style binary records | numbered files |

Every file is replaced atomically: it holds either its old contents or the
complete new result, never half of one. A path that is a device or a FIFO
(`-r /dev/null`) is written in place.

### Raw files

`binary` and `ascii` are ngspice raw files: a text header (title, date,
plot name, flags, variable list) followed by the data. Every plot of the
deck goes into the one file, back to back, the way ngspice writes them, so
any reader of ngspice raw files can load it. The date field is fixed, so
the same deck gives a byte-identical file.

```text
$ espice divider.sp -r divider.raw --format=ascii
$ cat divider.raw
Title: Voltage divider
Date: Thu Jan  1 00:00:00 1970
Plotname: Operating Point
Flags: real
No. Variables: 3
No. Points: 1
Variables:
	0	i(v1)	current
	1	v(in)	voltage
	2	v(out)	voltage
Values:
0	-2.5e-3
	1e1
	7.5e0
```

### Text and CSV

`print` writes each plot as a table, with a header row, a rule and one row
per point; complex columns get an `(imag)` column after them. It is the
format the [Learn SPICE](../learn/index.md) chapters show. `csv` writes
one plot per file with a header row; a complex column `v(out)` becomes
`v(out)_re` and `v(out)_im`:

```text
frequency_re,frequency_im,i(v1)_re,i(v1)_im,v(in)_re,v(in)_im,v(out)_re,v(out)_im
1e1,0e0,-9.979542742416352e-8,-9.989267655685869e-6,1e0,0e0,9.999002045725759e-1,-9.98926765568587e-3
```

### Touchstone and CITIfile

These hold S-parameters only, so they accept only an `.sp` (or `.lin`,
`.net`) result; anything else fails with `NotSParameterData`, and a deck
with no ports with `NoPorts`. Touchstone needs the full S matrix, written
in real-imaginary form at the ports' reference impedance:

```text
$ espice two_port.sp -r lc.s2p --format=touchstone
$ head -3 lc.s2p
! LC low-pass as a two-port
# Hz S RI R 50
1e6 1.9921236660280783e-8 9.96883205564205e-7 9.99800389223915e-1 -1.9979532194577303e-2 9.99800389223915e-1 -1.9979532194577303e-2 1.9921236660280783e-8 9.96883205563849e-7
```

CITIfile writes the frequency list and one real-imaginary `DATA` block per
S-parameter.

### PSF, FSDB and SST2

`psf` is Cadence's PSF ASCII: a multi-point plot writes its first variable
as the SWEEP and the rest as TRACEs. `fsdb` and `sst2` follow the record
structure of those formats only. FSDB proper is a closed Synopsys format,
so vendor tools that need `libfsdb` will not read ESPice's files; SST2
holds at most 64 variables and is untested against HSPICE's readers.
Prefer `binary` or `psf` for interchange.

## Choosing what is written

ngspice dialect: `.save` lists the vectors to keep; everything else is
dropped from the results.

```text
.save v(out) i(vdd)
```

Without `.save`, every node voltage and branch current is written.
`.print`, `.plot`, `.probe` and `.graph` are accepted and ignored for the
same reason. In the HSPICE dialect `.save` has HSPICE's meaning: it writes
the operating point as a loadable `.nodeset` or `.ic` file, beside the
output file.

## Measurements

`.meas` results print on stdout after the run, in ngspice's format:

```text
  Measurements for Transient Analysis

tphl                =  2.818778e-11 targ=  1.078188e-09 trig=  1.050000e-09
```

They are printed whether or not `--rawfile` is given. Over Monte Carlo
trials ESPice also prints the mean, sigma, min and max of each
measurement. [Chapter 7](../learn/measure.md) and the
[reference](reference.md#meas) cover the syntax.

HSPICE's `.stim` writes transient signals as PWL sources or a `.data`
table, and `.save` (HSPICE dialect) writes the operating point; both go
beside the output file, or the working directory without one. HSPICE's own
listing files (`.mt0`, `.lis`, `.err`) are not written.
