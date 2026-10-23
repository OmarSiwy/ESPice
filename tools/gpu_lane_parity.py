#!/usr/bin/env python3
"""GPU lane parity (phase 4 G9): every eligible .tran deck replicated as R
identical sweep rows, run as GPU lanes (--backend cuda) and as CPU lanes
(ESPICE_LANES=1, the oracle). Each GPU replica's columns must lie within the
corpus closeness of the CPU replica's, compared on the CPU time grid by
linear interpolation (the grids may desynchronize by one accept/reject), and
the R GPU replicas must be bitwise equal to each other (determinism). A deck
is eligible when espice reports `gpu-lanes: N lanes` under ESPICE_GPU_STATS.
  tools/gpu_lane_parity.py ESPICE [R] [deck...]   exit 1 on any miss."""
import bisect, os, pathlib, re, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

exe = os.path.abspath(sys.argv[1])
R = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 64
given = [pathlib.Path(a) for a in sys.argv[3 if len(sys.argv) > 2 and sys.argv[2].isdigit() else 2:]]
SWEEP = re.compile(r"^\s*\.(step|data|alter|mc)\b|\bsweep\b|^\s*\.temp\s+\S+\s+\S+", re.I | re.M)
CARD = re.compile(r"^\s*\.tran\b", re.I | re.M)
RTOL = 1e-3

import json

def tokenizer(deck):
    oracle = deck.with_suffix(".expected.json")
    try: return json.loads(oracle.read_text()).get("tokenizer") or "ngspice"
    except Exception: return "ngspice"

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



def run(deck, src, tmp, gpu):
    p = pathlib.Path(tmp) / deck.name
    p.write_text(src)
    raw = pathlib.Path(tmp) / ("gpu.raw" if gpu else "cpu.raw")
    env = dict(os.environ, ESPICE_GPU_STATS="1")
    args = [exe, "--jobs=1", "--format=binary", "-b", "-r", str(raw), "--tokenizer", tokenizer(deck)]
    if gpu:
        args += ["--backend", "cuda"]
    else:
        env["ESPICE_LANES"] = "1"
    r = subprocess.run(args + [p.name], cwd=tmp, env=env, capture_output=True, timeout=3600)
    return r.returncode, r.stderr.decode(errors="replace"), raw.read_bytes() if raw.exists() else b""


def columns(pl):
    _, nv, npt, cplx, data = pl
    vals = struct.unpack(f"<{nv * npt}d", data)
    return [[vals[i * nv + v] for i in range(npt)] for v in range(nv)]


def interp(t, y, at):
    k = bisect.bisect_left(t, at)
    if k < len(t) and t[k] == at:
        return y[k]
    if k == 0:
        return y[0]
    if k >= len(t):
        return y[-1]
    f = (at - t[k - 1]) / (t[k] - t[k - 1])
    return y[k - 1] + f * (y[k] - y[k - 1])


def check(deck):
    src0 = deck.read_text(errors="replace")
    rep = re.sub(r"^\s*\.end\s*$", ".param lane_rep=0\n.step param lane_rep list " + " ".join(str(i) for i in range(1, R + 1)) + "\n.end",
                 src0, flags=re.I | re.M)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["cp", "-r", str(deck.parent) + "/.", tmp], check=True)
        g = run(deck, rep, tmp, True)
        if "gpu-lanes:" not in g[1]:
            return None, None  # not eligible
        c = run(deck, rep, tmp, False)
    if g[0] != c[0]:
        return f"{deck}: rc gpu {g[0]} cpu {c[0]}", None
    pg, pc = plots(g[2]), plots(c[2])
    if len(pg) != len(pc):
        return f"{deck}: {len(pg)} GPU plots, {len(pc)} CPU", None
    tran = [k for k, p in enumerate(pc) if p[0].startswith("Transient")]
    worst = 0.0
    per = len(pc) // R if R and len(pc) % R == 0 else None
    for k in tran:
        if per and k >= per and pg[k][1:] != pg[k % per][1:]:
            return f"{deck}: GPU replica plot {k} differs from replica 0 (nondeterministic)", None
        gc, cc = columns(pg[k]), columns(pc[k])
        tg, tc = gc[0], cc[0]
        for v in range(1, len(cc)):
            peak = max((abs(x) for x in cc[v]), default=0.0)
            atol = 1e-3 * peak + 1e-15
            for t, want in zip(tc, cc[v]):
                got = interp(tg, gc[v], t)
                ratio = abs(got - want) / (RTOL * abs(want) + atol)
                worst = max(worst, ratio)
                if ratio > 1:
                    return f"{deck}: plot {k} var {v} t={t:.4e} gpu {got:.6e} cpu {want:.6e}", worst
    return None, worst


decks = given or sorted(p for p in pathlib.Path("tests/conformance/tests/netlist").rglob("*.sp")
                        if "invalid" not in p.parts and (t := p.read_text(errors="replace"))
                        and CARD.search(t) and not SWEEP.search(t))
eligible, bad, worst = 0, [], 0.0
with ThreadPoolExecutor(2) as pool:
    for deck, (msg, w) in zip(decks, pool.map(check, decks)):
        if w is not None:
            eligible += 1
            worst = max(worst, w)
        if msg:
            bad.append(msg)
print(f"{len(decks)} decks, {eligible} eligible, {len(bad)} miss; worst {worst * RTOL:.3g} of rtol {RTOL}")
for m in bad:
    print(m)
sys.exit(1 if bad else 0)
