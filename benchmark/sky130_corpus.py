#!/usr/bin/env python3
"""Generate reproducible SKY130 circuit families with synthetic interconnect RC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re


CORNERS = {"tt": (1.8, 27), "ss": (1.62, 125), "ff": (1.98, -40),
           "sf": (1.8, 27), "fs": (1.8, 27)}

# Observed design interfaces from MVM/scripts/components, not repaired extraction pins.
LAYOUT_PORTS = {
    "strongarm": "vinp vinn outp outn clk vdd vss".split(),
    "charge_dac": "vref b0 b1 b2 b3 out vdd vss".split(),
    "sample_hold_bank": "in0 in1 in2 out0 out1 out2 sh_ctrl vdd vss".split(),
    "imc_crossbar": "x0 x1 x2 y0 y1 y2 rst vdd vss".split() +
        [f"wb_{i}{j}{b}" for i in range(3) for j in range(3) for b in range(4)],
    "async_ctrl": "go adc_done xbar_rst adc_go latch_out done vdd vss".split(),
    "interleaved_adc": "col0 col1 col2 vref adc_go vdd vss".split() +
        [f"d{j}b{b}" for j in range(3) for b in range(4)],
    "gemm_tapeout": "clk ena rst_n vpwr vgnd".split() +
        [f"{bus}[{i}]" for bus in ("ui_in", "uio_in", "uo_out", "uio_out", "uio_oe") for i in range(8)],
}


def save_signals(nodes, sources):
    probes = [f"v({node})" for node in sorted(set(nodes) - {"0"})]
    probes += [f"i({name})" for name in sources]
    return [(".save " if i == 0 else "+ ") + " ".join(probes[i:i + 16]) for i in range(0, len(probes), 16)]


def extracted(root, out, library, corners):
    records = []
    paths = sorted(set(root.glob("*/*_extracted.spice")) | set(root.glob("*/*_pex.spice")) |
                   set(root.glob("*/*_extracted.cir")))
    if not paths:
        raise ValueError(f"no extracted layouts under {root}")
    for path in paths:
        source = path.read_bytes()
        text = re.sub(r"\r?\n\s*\+", " ", source.decode())
        declarations = re.findall(r"^\s*\.subckt\s+([^\n]+)", text, re.I | re.M)
        if len(declarations) != 1:
            raise ValueError(f"expected one top-level extracted subcircuit: {path}")
        top, *ports = declarations[0].split()
        ports = [p.lower() for p in ports]
        canonical = {"vss" if p in ("gnd", "sky130_gnd") else p for p in ports}
        family = path.parent.name
        missing = sorted(set(LAYOUT_PORTS[family]) - canonical)
        issues = ["missing design ports: " + ", ".join(missing)] if missing else []
        extra = sorted(canonical - set(LAYOUT_PORTS[family]))
        if extra:
            issues.append("unrecognized design ports: " + ", ".join(extra))
        if path.suffix == ".cir":
            issues.append("LVS primitive MOS cards require validated PDK binding; no model rewrite applied")
        record = {"path": str(path.resolve()), "sha256": hashlib.sha256(source).hexdigest(),
                  "top": top, "ports": ports, "quality_issues": issues,
                  "lvs": "unverified", "origin": source.decode().splitlines()[0],
                  "explicit_resistors": len(re.findall(r"^r\S+\s", text, re.I | re.M)),
                  "explicit_capacitors": len(re.findall(r"^c\S+\s", text, re.I | re.M)), "fixtures": []}
        for corner in corners:
            vdd, temp = CORNERS[corner]
            sources, nodes = [], []
            analog = next((i for i, p in enumerate(ports) if re.fullmatch(r"vinp|in\d+|x\d+|col\d+", p)), None)
            drive = f"V{analog}" if analog is not None else None
            for i, port in enumerate(ports):
                if port in ("vss", "gnd", "sky130_gnd", "vgnd"):
                    nodes.append("0")
                    continue
                nodes.append(port)
                if port in ("vdd", "vpwr", "vref", "ena", "rst_n"):
                    sources.append(f"V{i} {port} 0 {vdd}")
                elif re.fullmatch(r"vin[pn]|in\d+|x\d+|col\d+", port):
                    drive = drive or f"V{i}"
                    sources.append(f"V{i} {port} 0 DC {vdd / 2} AC {int(drive == f'V{i}')} SIN({vdd / 2} 0.05 1meg)")
                elif (port in ("clk", "go", "rst", "sh_ctrl", "adc_go", "adc_done") or
                      re.fullmatch(r"b\d+|wb_\d+|ui_in\[\d+\]|uio_in\[\d+\]", port)):
                    drive = drive or f"V{i}"
                    sources.append(f"V{i} {port} 0 DC 0 AC {int(drive == f'V{i}')} PULSE(0 {vdd} 1n 20p 20p 5n 10n)")
                else:
                    sources.append(f"Cload{i} {port} 0 5f")
            if drive is None:
                raise ValueError(f"no recognized drive port in {path}")
            for analysis in (".op", f".dc {drive} 0 {vdd} {vdd / 20}", ".ac dec 5 1k 1g", ".tran 10p 20n"):
                kind = analysis.split()[0][1:]
                label = f"{path.stem}_{path.suffix[1:]}_{corner}_{kind}"
                folder = out / "sky130_extracted" / label
                folder.mkdir(parents=True, exist_ok=True)
                lines = [f"Actual SKY130 extraction: {family}; interface/LVS quality recorded in manifest",
                         f'.lib "{library}" {corner}', f'.include "{path.resolve()}"',
                         f".options temp={temp} reltol=1e-4 abstol=1e-12 vntol=1e-6", *sources,
                         f"Xdut {' '.join(nodes)} {top}",
                         "* Compare DUT ports and source currents; device internal nodes are backend-specific.",
                         *save_signals(nodes, [line.split()[0] for line in sources if line.startswith("V")]),
                         analysis, ".end", ""]
                (folder / "circuit.sp").write_text("\n".join(lines))
                record["fixtures"].append(label)
        records.append(record)
    return records


def mos(name, drain, gate, source, bulk, polarity, width):
    return f"X{name} {drain} {gate} {source} {bulk} sky130_fd_pr__{polarity}fet_01v8 w={width} l=0.15"


def circuit(family, size, vdd):
    lines = [f"Vdd vdd 0 {vdd}"]
    if family == "inverter":
        lines += [f"Vin in 0 DC 0 AC 1 PULSE(0 {vdd} 1n 20p 20p 5n 10n)"]
        for i in range(size):
            gate = "in" if i == 0 else f"wire{i - 1}"
            lines += [mos(f"n{i}", f"out{i}", gate, "0", "0", "n", 0.42),
                      mos(f"p{i}", f"out{i}", gate, "vdd", "vdd", "p", 0.84),
                      f"Rwire{i} out{i} wire{i} 8", f"Cwire{i} wire{i} 0 4f"]
            if i:
                lines += [f"Ccouple{i} wire{i - 1} wire{i} 0.5f"]
        return lines, [".op", f".dc Vin 0 {vdd} {vdd / 20}", ".tran 10p 20n"]
    if family == "mirror":
        lines += ["Iref vdd bias 10u", mos("ref", "bias", "bias", "0", "0", "n", 1.26),
                  "Vin sink 0 DC 0.9 AC 1"]
        for i in range(size):
            lines += [mos(str(i), f"out{i}", "bias", "0", "0", "n", 1.26),
                      f"Rwire{i} sink out{i} 8", f"Cwire{i} out{i} 0 4f"]
        return lines, [".op", f".dc Vin 0 {vdd} {vdd / 20}", ".ac dec 5 1k 1g"]
    # Independent differential pairs, shared supply; asymmetric wire RC exposes crosstalk.
    lines += ["Vin inp 0 DC 0.9 AC 1", "Vinn inn 0 DC 0.9"]
    for i in range(size):
        lines += [mos(f"a{i}", f"a{i}", "inp", f"tail{i}", "0", "n", 1.26),
                  mos(f"b{i}", f"b{i}", "inn", f"tail{i}", "0", "n", 1.26),
                  f"Itail{i} tail{i} 0 10u", f"Ra{i} vdd a{i} 100k", f"Rb{i} vdd b{i} 100k",
                  f"Rwire{i} a{i} out{i} 8", f"Ca{i} out{i} 0 4f", f"Cb{i} b{i} 0 5f",
                  f"Ccouple{i} out{i} b{i} 0.5f"]
    return lines, [".op", ".dc Vin 0.8 1.0 0.01", ".ac dec 5 1k 1g", ".noise v(out0) Vin dec 5 1k 1g"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdk", type=Path, default=os.environ.get("PDK_ROOT"),
                        help="sky130A directory, or parent containing sky130A; defaults to PDK_ROOT")
    parser.add_argument("--out", type=Path, default=Path("zig-out/sky130-fixtures"))
    parser.add_argument("--sizes", type=int, nargs="+", default=[4, 64, 1024])
    parser.add_argument("--corners", choices=list(CORNERS), nargs="+", default=list(CORNERS))
    parser.add_argument("--layout-root", type=Path, action="append", default=[],
                        help="directory containing FAMILY/*_extracted.spice or *_pex.spice; repeatable")
    args = parser.parse_args()
    if args.pdk is None:
        parser.error("--pdk or PDK_ROOT required; level-1 model substitutes are forbidden")
    pdk = args.pdk.resolve()
    if (pdk / "sky130A").is_dir():
        pdk /= "sky130A"
    library = pdk / "libs.tech/ngspice/sky130.lib.spice"
    if not library.is_file():
        parser.error(f"missing actual SKY130 library: {library}")
    if any(size < 1 or size > 65535 for size in args.sizes):
        parser.error("sizes must be in [1, 65535]")
    count = 0
    for corner in args.corners:
        vdd, temp = CORNERS[corner]
        for family in ("inverter", "mirror", "diffpair"):
            for size in args.sizes:
                devices, analyses = circuit(family, size, vdd)
                for analysis in analyses:
                    kind = analysis.split()[0][1:]
                    folder = args.out / "sky130" / f"{family}_{size}_{corner}_{kind}"
                    folder.mkdir(parents=True, exist_ok=True)
                    header = [f"SKY130 {family}: {size} instances, {corner}, {vdd} V, {temp} C",
                              "* Synthetic interconnect RC, not a production-extracted layout.",
                              f'.lib "{library}" {corner}', f".options temp={temp} reltol=1e-4 abstol=1e-12 vntol=1e-6"]
                    nodes = [node for line in devices for node in line.split()[1:5 if line.startswith("X") else 3]]
                    saved = save_signals(nodes, [line.split()[0] for line in devices if line.startswith("V")])
                    if kind == "noise":
                        saved = [".save onoise_spectrum inoise_spectrum onoise_total inoise_total"]
                    (folder / "circuit.sp").write_text("\n".join(header + devices + saved + [analysis, ".end", ""]))
                    count += 1
    provenance = {"pdk": str(pdk), "revision": pdk.parent.name,
                  "models": "actual SKY130 nfet_01v8 and pfet_01v8 wrappers, no substitutes",
                  "layout": "synthetic RC: 8 ohm wire, 4/5 fF ground, 0.5 fF coupling",
                  "families": ["inverter", "mirror", "diffpair"], "sizes": args.sizes,
                  "corners": {corner: CORNERS[corner] for corner in args.corners}, "fixtures": count}
    provenance["extractions"] = [record for root in args.layout_root
                                 for record in extracted(root, args.out, library, args.corners)]
    extracted_count = sum(len(record["fixtures"]) for record in provenance["extractions"])
    (args.out / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Created {count} synthetic + {extracted_count} actual-extraction fixtures in {args.out}; PDK revision {pdk.parent.name}")


if __name__ == "__main__":
    main()
