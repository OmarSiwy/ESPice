#!/usr/bin/env python3
"""Compare HSPICE's .mt0 measures with ESPice's per-point .meas blocks.

Usage: compare_hspice.py deck.mt0 espice_stdout.txt [rtol]

HSPICE writes one .mt0 row per .data point (the sweep parameters, the
measures, temper, alter#). ESPice prints one block per point:
"Measurements for Transient Analysis, point K (...)" then "name = value".
Points are matched by index (both follow the .data row order). Prints the
worst relative difference per measure and every point beyond rtol.
"""
import math, re, sys


def num(tok):
    try:
        return float(tok)
    except ValueError:
        return None


def read_mt0(path):
    toks = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("$") or s.upper().startswith(".TITLE"):
                continue
            toks += s.split()
    first = next(i for i, t in enumerate(toks) if num(t) is not None or t.lower() == "failed")
    names = [t.lower() for t in toks[:first]]
    vals = [num(t) if t.lower() != "failed" else math.nan for t in toks[first:]]
    k = len(names)
    rows = [dict(zip(names, vals[i:i + k])) for i in range(0, len(vals) - k + 1, k)]
    return rows


def read_espice(path):
    points, cur = {}, None
    head = re.compile(r"Measurements for .*?point (\d+)")
    line_re = re.compile(r"^(\w+)\s*=\s*(\S+)")
    with open(path) as f:
        for line in f:
            m = head.search(line)
            if m:
                cur = points.setdefault(int(m.group(1)), {})
                continue
            m = line_re.match(line.strip())
            if m and cur is not None:
                v = num(m.group(2))
                cur[m.group(1).lower()] = math.nan if v is None else v
    return [points[k] for k in sorted(points)]


def main():
    mt0, esp = read_mt0(sys.argv[1]), read_espice(sys.argv[2])
    rtol = float(sys.argv[3]) if len(sys.argv) > 3 else 1e-2
    if len(mt0) != len(esp):
        print(f"point count differs: hspice {len(mt0)}, espice {len(esp)}")
    names = [n for n in (esp[0] if esp else {}) if mt0 and n in mt0[0]]
    worst = {n: (0.0, -1) for n in names}
    bad = 0
    for i, (h, e) in enumerate(zip(mt0, esp)):
        for n in names:
            a, b = h[n], e[n]
            if math.isnan(a) or math.isnan(b):
                if math.isnan(a) != math.isnan(b):
                    print(f"point {i} {n}: hspice {a} espice {b}")
                    bad += 1
                continue
            rel = abs(a - b) / max(abs(a), 1e-30)
            if rel > worst[n][0]:
                worst[n] = (rel, i)
            if rel > rtol:
                bad += 1
                print(f"point {i} {n}: hspice {a:.6e} espice {b:.6e} rel {rel:.2e}")
    print(f"{min(len(mt0), len(esp))} points compared, {bad} beyond rtol {rtol:g}")
    for n, (rel, i) in worst.items():
        print(f"  {n:10s} worst rel {rel:.3e} at point {i}")


if __name__ == "__main__":
    main()
