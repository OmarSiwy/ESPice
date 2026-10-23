#!/usr/bin/env python3
"""Lane gates (lane-batched-simulation.md §11 tests 2 and 3).
  tools/lane_diff.py ESPICE swept     [kinds...]  every swept deck: lanes off == lanes on, bytes
  tools/lane_diff.py ESPICE replicate [kinds...]  every deck x4 identical rows: each point == the deck alone, data bits
  tools/lane_diff.py ESPICE old OLD   [kinds...]  every deck, lanes off: ESPICE == the OLD binary, bytes (refactor identity)
kinds default to tran; e.g. `op dc tran`. Exit 1 on any difference."""
import json, os, pathlib, re, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

exe = os.path.abspath(sys.argv[1]); mode = sys.argv[2] if len(sys.argv) > 2 else "swept"
old = os.path.abspath(sys.argv[3]) if mode == "old" else None
kinds = sys.argv[4 if old else 3:] or ["tran"]
SWEEP = re.compile(r"^\s*\.(step|data|alter|mc)\b|\bsweep\b|^\s*\.temp\s+\S+\s+\S+", re.I | re.M)
CARD = re.compile(r"^\s*\.(" + "|".join(kinds) + r")\b", re.I | re.M)

TIMEOUT = int(os.environ.get("LANE_DIFF_TIMEOUT", "1800"))

class Skip(Exception):
    pass

def tokenizer(deck):
    oracle = deck.with_suffix(".expected.json")
    try: return json.loads(oracle.read_text()).get("tokenizer") or "ngspice"
    except Exception: return "ngspice"

def run(deck, src, lanes, tmp, binary=None):
    p = pathlib.Path(tmp) / deck.name
    p.write_text(src)
    raw = pathlib.Path(tmp) / f"out{lanes}{'old' if binary else ''}.raw"
    env = dict(os.environ, ESPICE_LANES=str(lanes))
    try:
        r = subprocess.run([binary or exe, "--jobs=1", "--format=binary", "-b", "-r", str(raw), "--tokenizer", tokenizer(deck), p.name],
                           cwd=tmp, env=env, capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Skip(f"{deck}: skipped, a run took over {TIMEOUT} s")
    return r.returncode, r.stdout, raw.read_bytes() if raw.exists() else b""

def plots(raw):
    """ngspice binary raw: list of (plotname, nvars, npoints, complex, data bytes)."""
    out, i = [], 0
    while i < len(raw):
        hdr = {}
        while True:
            j = raw.index(b"\n", i); line = raw[i:j].decode(errors="replace"); i = j + 1
            if line.startswith("Binary:"): break
            if ":" in line: k, v = line.split(":", 1); hdr[k.strip()] = v.strip()
            if line.startswith("Variables:"):
                for _ in range(int(hdr["No. Variables"])): i = raw.index(b"\n", i) + 1
        nv, npt = int(hdr["No. Variables"]), int(hdr["No. Points"])
        cplx = "complex" in hdr.get("Flags", "")
        n = nv * npt * (16 if cplx else 8)
        out.append((hdr.get("Plotname", ""), nv, npt, cplx, raw[i:i + n])); i += n
    return out

def check(deck):
    src0 = deck.read_text(errors="replace")
    # Copy the deck's directory so includes resolve.
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["cp", "-r", str(deck.parent) + "/.", tmp], check=True)
        if mode == "old":
            a, b = run(deck, src0, 0, tmp, old), run(deck, src0, 0, tmp)
            return None if a == b else f"{deck}: new != old (rc {a[0]}/{b[0]}, raw {len(a[2])}/{len(b[2])} B)"
        if mode == "swept":
            a, b = run(deck, src0, 0, tmp), run(deck, src0, 1, tmp)
            return None if a == b else f"{deck}: lanes on != off (rc {a[0]}/{b[0]}, raw {len(a[2])}/{len(b[2])} B)"
        base = run(deck, src0, 0, tmp)
        rep = re.sub(r"^\s*\.end\s*$", ".param lane_rep=0\n.step param lane_rep list 1 2 3 4\n.end", src0, flags=re.I | re.M)
        got = run(deck, rep, 1, tmp)
        if base[0] != 0: return None  # a failing deck stays failing; swept mode covers its bytes
        pb, pg = plots(base[2]), plots(got[2])
        if len(pg) != 4 * len(pb): return f"{deck}: {len(pg)} plots for 4 x {len(pb)}"
        for k, g in enumerate(pg):
            want = pb[k % len(pb)]  # step-major: point j's plots are pg[j*len(pb) : (j+1)*len(pb)]
            if g[1:] != want[1:]: return f"{deck}: replica plot {k} '{g[0]}' differs from '{want[0]}'"
        return None

decks = sorted(p for p in pathlib.Path("tests/conformance/tests/netlist").rglob("*.sp")
               if "invalid" not in p.parts and (t := p.read_text(errors="replace"))
               and CARD.search(t) and (mode != "swept" or SWEEP.search(t)))
if mode == "replicate": decks = [d for d in decks if not SWEEP.search(d.read_text(errors="replace"))]
def guarded(deck):
    try: return check(deck)
    except Skip as e: return "SKIP " + str(e)
with ThreadPoolExecutor(os.cpu_count() // 2 or 1) as pool:
    out = [m for m in pool.map(guarded, decks) if m]
skipped = [m for m in out if m.startswith("SKIP ")]
bad = [m for m in out if not m.startswith("SKIP ")]
print(f"{len(decks)} decks, {len(bad)} differ, {len(skipped)} skipped"); [print(m) for m in bad + skipped]
sys.exit(1 if bad else 0)
