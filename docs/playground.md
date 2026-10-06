# Playground

Every netlist on this site runs in your browser. Edit it and the schematic
redraws. Press **Run** and ESPice, compiled to WebAssembly, simulates it on
your machine. Nothing is sent to a server.

## RC low-pass: transient

A 1 kΩ, 1 nF low-pass (τ = 1 µs) driven by a 5 µs pulse. `v(out)` charges
toward 1 V and discharges once the pulse ends.

```spice
RC low-pass step response
V1 in 0 PULSE(0 1 0 1n 1n 5u 10u)
R1 in out 1k
C1 out 0 1n
.tran 10n 20u
.end
```

## Diode: DC sweep

A diode with 0.5 Ω series resistance behind 100 Ω, swept from 0 to 2 V.
The current stays near zero until about 0.6 V, then the resistors limit it.

```spice
Diode forward sweep
V1 a 0 0
R1 a k 100
D1 k 0 dmod
.model dmod d(is=1e-14 n=1.05 rs=0.5)
.dc V1 0 2 0.01
.end
```

## CMOS inverter: operating point and transfer curve

Level-1 MOSFETs on a 1.8 V supply. The `.op` table shows the bias at
mid-rail, and the `.dc` sweep traces the transfer curve.

```spice
CMOS inverter
Vdd vdd 0 1.8
Vin in 0 0.9
M1 out in 0 0 nch w=1u l=0.18u
M2 out in vdd vdd pch w=2.5u l=0.18u
.model nch nmos level=1 vto=0.45 kp=270u lambda=0.1
.model pch pmos level=1 vto=-0.45 kp=70u lambda=0.1
.op
.dc Vin 0 1.8 0.01
.end
```

## What the browser build can't do

- **Built-in models only.** `.hdl` compiles Verilog-A with a Zig compiler at
  run time, and the browser has none. Every model built into ESPice is
  compiled in.
- **No files.** There is no file system, so `.include`, `.lib` with a file,
  and the `wrdata` and `.save` outputs are not available. Paste the models
  into the deck instead.
- **One thread, CPU only.** GitHub Pages can't send the headers that
  shared-memory threads need, so the analyses run one after another on one
  core, with no GPU. A simulation runs on the page's own thread, so a long
  transient freezes the tab until it finishes.
- **Memory.** WebAssembly gets at most 4 GB, and the tab's limit is often
  lower. Decks with tens of thousands of devices belong on the native
  `espice`.

For anything past these limits, [build ESPice](https://github.com/OmarSiwy/ESPice)
and run the same deck from the command line.
