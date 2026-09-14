#!/usr/bin/env python3
"""Fail-closed fixture execution; analytical checks are separate from smoke coverage."""
import argparse
import bisect
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import tempfile


PLOTS = dict(zip(
    "ac dc dcmatch disto envelope four hb matex mc noise op pac pnoise pss pxf pz qpss sens sp stb temp tf tran tran_noise".split(),
    ["AC Analysis", "DC transfer characteristic", "DC Mismatch", "Distortion Analysis",
     "Envelope Analysis", "Fourier Analysis", "Harmonic Balance", "MATEX Transient Analysis",
     "Monte Carlo", "Noise Analysis", "Operating Point", "Periodic AC Analysis",
     "Periodic Noise Analysis", "Periodic Steady State", "Periodic Transfer Function Analysis",
     "Pole-Zero Analysis", "Quasi-Periodic Steady State",
     "Sensitivity Analysis",  # ngspice's own newAnalysis string, inp2dot.c:461
     "SP Analysis",  # ngspice's own newAnalysis string, inp2dot.c:710

     "Stability Analysis", "Temperature Sweep", "Transfer Function", "Transient Analysis",
     "Transient Noise Analysis"]))


def read_raw(path):
    """Read ngspice/ESPice binary real and complex plots, requiring complete payloads."""
    blob = path.read_bytes()
    plots = []
    while blob.strip():
        header, marker, blob = blob.partition(b"Binary:\n")
        if not marker:
            raise ValueError("missing binary plot")
        text = header.decode()
        nv = int(re.search(r"No\. Variables:\s*(\d+)", text)[1])
        np = int(re.search(r"No\. Points:\s*(\d+)", text)[1])
        if nv < 1 or np < 1:
            raise ValueError("empty plot")
        names = [line.split()[1].lower() for line in text.split("Variables:\n", 1)[1].splitlines() if line.strip()]
        if len(names) != nv or len(set(names)) != nv:
            raise ValueError("missing or duplicate variables")
        width = 2 if "complex" in re.search(r"Flags:(.*)", text)[1] else 1
        size = nv * np * width * 8
        if len(blob) < size:
            raise ValueError("truncated samples")
        values = struct.unpack(f"={nv * np * width}d", blob[:size])
        if not all(math.isfinite(x) for x in values):
            raise ValueError("non-finite samples")
        samples = [complex(values[i], values[i + 1]) for i in range(0, len(values), 2)] if width == 2 else values
        columns = {name: samples[i::nv] for i, name in enumerate(names)}
        title = re.search(r"Plotname:(.*)", text)[1].strip()
        if re.search(r"not converge|stopped early", title, re.I):
            raise ValueError(f"unsuccessful plot: {title}")
        plots.append((title, columns))
        blob = blob[size:]
    if not plots:
        raise ValueError("no plots")
    return plots


def close(actual, expected, atol=1e-8, rtol=1e-5):
    if abs(actual - expected) > atol + rtol * abs(expected):
        raise ValueError(f"{actual} != {expected} (atol={atol}, rtol={rtol})")


def analytical(name, columns):
    if name == "op":
        close(columns["v(out)"][0], 7.5)
    elif name == "dc":
        for vin, out in zip(columns["v(in)"], columns["v(out)"]):
            close(out, 0.75 * vin)
        if len(columns["v(out)"]) != 11:
            raise ValueError("DC sweep must contain 11 points")
    elif name == "ac":
        for freq, out in zip(columns["frequency"], columns["v(out)"]):
            close(out, 1 / (1 + 2j * math.pi * freq.real * 1e-3))
    elif name == "temp":
        for out in columns["v(out)"]:
            close(out, 7.5)
    elif name == "sens":
        # Named after the CARD now, as ngspice does (cktsens.c:224-238). Same values.
        close(columns["v(r1)"][0], -0.001875)
        close(columns["v(r2)"][0], 0.000625)
    elif name == "dcmatch":
        close(columns["resistor#0.r"][0], -0.001875)
        close(columns["resistor#1.r"][0], 0.000625)
    elif name == "tf":
        for column, expected in (("transfer_function", 0.75), ("input_resistance", 4000), ("output_resistance", 750)):
            close(columns[column][0], expected)
    elif name == "mc":
        if tuple(columns["run"]) != (0, 1, 2, 3) or len(set(columns["v(out)"])) < 2:
            raise ValueError("Monte Carlo must vary output across four trials")
        return "metamorphic"
    elif name == "mesh_op":
        if sum(bool(re.fullmatch(r"v\(n\d+_\d+\)", n)) for n in columns) != 64:
            raise ValueError("mesh must contain 64 node signals")
        for name, values in columns.items():
            match = re.fullmatch(r"v\(n\d+_(\d+)\)", name)
            if match:
                close(values[0], (8 - int(match[1])) / 9)
    elif name == "coupled_ac":
        if sum(n.startswith("v(out") for n in columns) != 16:
            raise ValueError("coupled routes must contain 16 output signals")
        for name, values in columns.items():
            if name.startswith("v(out"):
                for freq, out in zip(columns["frequency"], values):
                    close(out, 1 / (1 + 2j * math.pi * freq.real * 1e-6))
    elif name == "metal_island_tran":
        for value in columns["v(metal)"]:
            close(value, 0)
        close(columns["v(in)"][-1], 2)
    elif name == "capacitive_divider_tran":
        for vin, island in zip(columns["v(in)"], columns["v(island)"]):
            close(island, vin / 2)
        close(columns["v(island)"][0], 0.5)
        close(columns["v(island)"][-1], 1)
    else:
        return False
    return "analytical"


def compare(actual, reference, rtol):
    if len(actual) != len(reference):
        raise ValueError("reference plot count differs")
    for (_, ours), (_, theirs) in zip(actual, reference):
        # ngspice names branch currents i(v1); normalize its older v1#branch form.
        ours = {re.sub(r"^(.+)#branch$", r"i(\1)", n): v for n, v in ours.items()}
        theirs = {re.sub(r"^(.+)#branch$", r"i(\1)", n): v for n, v in theirs.items()}
        axis = next((n for n in ("time", "frequency", "v(v-sweep)", "v-sweep", "i-sweep") if n in theirs), None)
        signals = [name for name in theirs if name != axis]
        tx = [v.real for v in theirs[axis]] if axis else [0]
        ox = [v.real for v in ours[axis]] if axis in ours else []
        if not axis and any(len(v) != 1 for v in list(theirs.values()) + list(ours.values())):
            raise ValueError("unsupported multirow plot without sweep axis")
        if len(tx) > 1 and (len(ox) < 2 or
                           (ox[0] > tx[0] and not math.isclose(ox[0], tx[0], rel_tol=1e-12, abs_tol=1e-18)) or
                           (ox[-1] < tx[-1] and not math.isclose(ox[-1], tx[-1], rel_tol=1e-12, abs_tol=1e-18))):
            raise ValueError("incomplete reference interval")
        if any(b <= a for a, b in zip(ox, ox[1:])):
            raise ValueError("non-monotone axis: split nested sweeps before comparison")
        for name in signals:
            if name not in ours:
                raise ValueError(f"missing reference signal {name}")
            atol = 1e-30 if "noise" in name else 1e-12 if name.startswith("i(") else 1e-6
            for j, expected in enumerate(theirs[name]):
                if len(tx) == 1:
                    value = ours[name][0]
                else:
                    i = min(max(bisect.bisect_left(ox, tx[j]), 1), len(ox) - 1)
                    fraction = (tx[j] - ox[i - 1]) / (ox[i] - ox[i - 1])
                    value = ours[name][i - 1] * (1 - fraction) + ours[name][i] * fraction
                try:
                    close(value, expected, atol=atol, rtol=rtol)
                except ValueError as error:
                    raise ValueError(f"{name}, sample {j}: {error}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", default="zig-out/bin/espice")
    parser.add_argument("--fixtures", type=Path, default=Path("benchmark/fixtures"))
    parser.add_argument("--category", default="golden")
    parser.add_argument("--reference", action="store_true", help="require ngspice agreement for every selected deck")
    parser.add_argument("--allow-unsupported", action="store_true", help="accept verified STB rejection as capability coverage, never accuracy")
    parser.add_argument("--backend", choices=["cpu", "cuda", "hip"], default="cpu")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--rtol", type=float, default=1e-3)
    args = parser.parse_args()
    if not math.isfinite(args.rtol) or args.rtol < 0:
        parser.error("rtol must be finite and nonnegative")
    failures = 0
    unsupported = 0
    fixtures = sorted((args.fixtures / args.category).glob("*/circuit.sp"))
    extractions = {}
    if args.category == "sky130_extracted":
        provenance = json.loads((args.fixtures / "PROVENANCE.json").read_text())
        extractions = {fixture: record for record in provenance["extractions"] for fixture in record["fixtures"]}
    if not fixtures:
        parser.error("no fixtures selected")
    if args.category == "golden":
        missing = PLOTS.keys() - {path.parent.name for path in fixtures}
        if missing:
            parser.error(f"missing analysis fixtures: {sorted(missing)}")
    for path in fixtures:
        label = f"{args.category}/{path.parent.name}"
        try:
            if args.category == "sky130_extracted":
                record = extractions[path.parent.name]
                if hashlib.sha256(Path(record["path"]).read_bytes()).hexdigest() != record["sha256"]:
                    raise ValueError("extracted source changed; regenerate corpus and provenance")
                if record["quality_issues"]:
                    raise ValueError("invalid extraction: " + "; ".join(record["quality_issues"]))
            with tempfile.TemporaryDirectory(prefix="espice-fixture-") as tmp:
                raw = Path(tmp) / "ours.raw"
                result = subprocess.run([str(Path(args.engine).resolve()), "-b", "--backend", args.backend,
                                         "-r", str(raw), str(path.resolve())], capture_output=True,
                                        text=True, timeout=args.timeout)
                if (args.category == "golden" and path.parent.name == "stb" and result.returncode and
                        result.stdout.strip() == '{"skip":"UnsupportedStabilityAnalysis"}'):
                    unsupported += 1
                    print(f"XFAIL {label}: unsupported capability rejected; no accuracy coverage")
                    continue
                if result.returncode or '"skip"' in result.stdout:
                    raise ValueError((result.stdout + result.stderr)[-1500:])
                if re.search(r"not converge|stopped early|falling back to the CPU", result.stdout + result.stderr, re.I):
                    raise ValueError(result.stderr[-1500:])
                if args.backend != "cpu" and re.search(r"--gpu declined|--gpu unavailable|running on the CPU", result.stderr, re.I):
                    raise ValueError(result.stderr[-1500:])
                plots = read_raw(raw)
                checked = False
                if args.category == "golden":
                    expected = PLOTS[path.parent.name]
                    matches = [cols for title, cols in plots if title.startswith(expected)]
                    if len(matches) != 1:
                        raise ValueError(f"expected {expected}; got {[title for title, _ in plots]}")
                    checked = analytical(path.parent.name, matches[0])
                elif args.category == "layout":
                    checked = analytical(path.parent.name, plots[0][1])
                if args.category in ("layout", "sky130", "sky130_extracted"):
                    kind = path.parent.name.rsplit("_", 1)[-1]
                    if kind in PLOTS and (len(plots) != 1 or plots[0][0] != PLOTS[kind]):
                        raise ValueError(f"expected single {PLOTS[kind]} plot")
                if args.reference:
                    ref = Path(tmp) / "reference.raw"
                    run = subprocess.run(["ngspice", "-b", "-r", str(ref), str(path.resolve())],
                                         capture_output=True, text=True, timeout=args.timeout)
                    if run.returncode:
                        raise ValueError("ngspice failed: " + run.stderr[-1500:])
                    compare(plots, read_raw(ref), args.rtol)
                print(f"PASS {label}: {'reference' if args.reference else checked or 'finite plot smoke only'}")
        except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
            failures += 1
            print(f"FAIL {label}: {error}")
    print(f"{len(fixtures) - failures - unsupported}/{len(fixtures)} passed; {unsupported} unsupported")
    return bool(failures or (unsupported and not args.allow_unsupported))


if __name__ == "__main__":
    raise SystemExit(main())
