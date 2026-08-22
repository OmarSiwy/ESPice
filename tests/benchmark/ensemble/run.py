#!/usr/bin/env python3
"""Times one ensemble proxy (gen.py) on each backend; dev/research/gpu-ensemble.md.

  run.py ESPICE DIR [cpu1|cpu8|cuda|cudalu|singles|singles_cuda|parP ...]

Prints one line per configuration: analysis ms (the sum of each deck's
`run total`, which excludes parse and setup), Newton iterations, accepted
transient steps, the Newton loop's split. A GPU configuration first runs
single_0.sp in the same process, untimed, so the CUDA context and the
model modules are warm, as in a long-lived ensemble. `singles` runs every
single_<k>.sp in one process on one host thread: the per-point CPU
baseline. `cudalu` forces the device LU. `parP` (par24) runs each
single_<k>.sp in its own process, P at a time, and prints the wall time,
which also pays each process's start, parse and setup (about 2 ms here).
`check` compares every point of stacked.sp (cpu1) with its single run,
stacked.sp on cuda with cpu1, and two cuda runs bitwise.
"""
import csv
import glob
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CONFIGS = {
    "cpu1": (["--backend=cpu"], {"ESPICE_THREADS": "1"}),
    "cpu8": (["--backend=cpu"], {"ESPICE_THREADS": "8"}),
    "cuda": (["--backend=cuda"], {"ESPICE_GPU_LU": "0", "ESPICE_THREADS": "1"}),
    "cudalu": (["--backend=cuda"], {"ESPICE_GPU_LU": "1", "ESPICE_THREADS": "1", "ESPICE_GPU_STATS": "1"}),
}


def singles(d):
    return sorted(glob.glob(f"{d}/single_*.sp"), key=lambda p: int(re.findall(r"\d+", os.path.basename(p))[0]))


def timed(exe, args, env, decks, warm):
    """`warm` runs first in the same process and is left out of the sums:
    it pays the driver and module setup a long-lived ensemble pays once."""
    e = dict(os.environ, **env)
    out = subprocess.run([exe, "--timing-in-depth", *args, *([warm] if warm else []), *decks], env=e,
                         capture_output=True, text=True, check=True).stderr
    if warm:
        out = out[list(re.finditer(r"^timing: \S+\.sp$", out, re.M))[1].start():]
    ms = sum(float(m) for m in re.findall(r"run total \(analysis, scheduling, output\): ([\d.]+)ms", out))
    iters = sum(int(m) for m in re.findall(r"newton: iterations=(\d+)", out))
    # The last attempt line of each transient carries its accepted count.
    steps = sum(int(m) for m in re.findall(r"accepted=(\d+) t=[^\n]*next_dt=0\.0", out))

    def total(key):
        return sum(float(m) for m in re.findall(rf"newton:[^\n]* {key}=([\d.]+)ms", out))
    split = f"eval={total('eval'):.0f} lu={total('factor') + total('solve'):.0f} update={total('update'):.0f}"
    peels = sum(int(m) for m in re.findall(r"gpu-lu: calls=\d+ refactors=\d+ peels=(\d+)", out))
    return ms, iters, steps, f"{split} gpu_lu_peels={peels}"


def table(exe, path, args=()):
    rows = list(csv.reader(subprocess.run([exe, *args, "-r", "/dev/stdout", "--format=csv", path],
                                          capture_output=True, text=True, check=True).stdout.splitlines()))
    head, body = rows[0], [[float(x) for x in r] for r in rows[1:]]
    return head, body


def crossings(t, y):
    """Times where y crosses the middle of its range; none for a flat node."""
    lo, hi = min(y), max(y)
    if hi - lo < 0.1:
        return []
    mid = (lo + hi) / 2
    return [t[i] + (mid - y[i]) * (t[i + 1] - t[i]) / (y[i + 1] - y[i])
            for i in range(len(y) - 1) if (y[i] - mid) * (y[i + 1] - mid) < 0]


def compare(a, b, names):
    """(worst |dv| at the last row, worst |dt| of matched mid-swing
    crossings, crossing-count mismatches) between two tables over `names`."""
    (ah, ab), (bh, bb) = a, b
    dv = dt = 0.0
    miss = 0
    for name in names:
        i, j = ah.index(name), bh.index(name)
        dv = max(dv, abs(ab[-1][i] - bb[-1][j]))
        if ah[0] != "time":
            continue
        ca = crossings([r[0] for r in ab], [r[i] for r in ab])
        cb = crossings([r[0] for r in bb], [r[j] for r in bb])
        miss += len(ca) != len(cb)
        dt = max([dt] + [abs(x - y) for x, y in zip(ca, cb)])
    return dv, dt, miss


def check(exe, d):
    """Every point of stacked.sp (cpu1) against its single run; stacked.sp
    on cuda against cpu1 (the H14 oracle); two cuda runs bitwise."""
    cpu = table(exe, f"{d}/stacked.sp")
    out = []
    worst = [0.0, 0.0, 0]
    for path in singles(d):
        one = table(exe, path)
        r = compare(cpu, one, [n for n in one[0] if n.startswith("v(")])
        worst = [max(worst[0], r[0]), max(worst[1], r[1]), worst[2] + r[2]]
    out.append(f"lockstep_vs_single last_dv={worst[0]:.2e}V cross_dt={worst[1] * 1e12:.3g}ps miss={worst[2]}")
    gpu = table(exe, f"{d}/stacked.sp", ["--backend=cuda"])
    r = compare(cpu, gpu, [n for n in cpu[0] if n.startswith("v(")])
    out.append(f"cuda_vs_cpu last_dv={r[0]:.2e}V cross_dt={r[1] * 1e12:.3g}ps miss={r[2]}")
    out.append(f"cuda_repeat_bitwise={gpu == table(exe, f'{d}/stacked.sp', ['--backend=cuda'])}")
    return " ".join(out)


def main():
    exe, d, *which = sys.argv[1:]
    for w in which:
        if w == "check":
            print(f"{d} check {check(exe, d)}", flush=True)
            continue
        if w.startswith("par"):
            env = dict(os.environ, ESPICE_THREADS="1")
            t0 = time.perf_counter()
            with ThreadPoolExecutor(int(w[3:])) as pool:
                for r in pool.map(lambda p: subprocess.run([exe, "--backend=cpu", p], env=env, capture_output=True),
                                  singles(d)):
                    r.check_returncode()
            print(f"{d} {w} wall_ms={(time.perf_counter() - t0) * 1e3:.1f}", flush=True)
            continue
        if w.startswith("singles"):
            args, env = CONFIGS["cuda" if w == "singles_cuda" else "cpu1"]
            decks = singles(d)
        else:
            (args, env), decks = CONFIGS[w], [f"{d}/stacked.sp"]
        warm = singles(d)[0] if "--backend=cuda" in args else None
        ms, iters, steps, split = timed(exe, args, env, decks, warm)
        print(f"{d} {w} ms={ms:.1f} iters={iters} steps={steps} {split}", flush=True)


if __name__ == "__main__":
    main()
