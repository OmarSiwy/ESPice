#!/usr/bin/env python3
"""One 5-inverter RC chain (BSIM4 LEVEL=54), swept SPICE-natively over n points.

  sweepdeck.py --form data  -n 1000 > d.sp   .data table of pwn pwp pl pr pc, .tran ... sweep data=
  sweepdeck.py --form step  -n 1000 > d.sp   .step param pr list (n values)
  sweepdeck.py --form monte -n 1000 > d.sp   .tran ... sweep monte=n over agauss params
  sweepdeck.py --form temp  -n 1000 > d.sp   .step temp list (n values)
  sweepdeck.py --selftest

Run with `espice --tokenizer=hspice`. Values are SI, so every swept
instance parameter equals its column and `variants.zig` takes the fast path.
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tests", "benchmark", "postlayout"))
from gen import TECH  # noqa: E402  the corpus BSIM4 cards

VDD = TECH["bsim4"]["vdd"]


def row(k, seed=1):
    """Point k's sizes and parasitics: wn wp l r c."""
    r = random.Random(seed * 1_000_003 + k)
    wn = r.uniform(0.2, 0.8)
    return [wn * 1e-6, wn * r.uniform(1.5, 2.5) * 1e-6, r.uniform(0.1, 0.15) * 1e-6, r.uniform(50, 500), r.uniform(0.5, 5) * 1e-15]


def deck(form, n, stages=5, tstep="1p", tstop="4n"):
    nom = row(0)
    out = [f"* sweep: {form} over {n} points of one {stages}-inverter RC chain (bsim4)",
           TECH["bsim4"]["cards"].rstrip("\n"),
           ".subckt chain in out vdd wn=1u wp=1u l=0.1u r=100 c=1f"]
    for i in range(1, stages + 1):
        a = "in" if i == 1 else f"b{i - 1}"
        b = "out" if i == stages else f"b{i}"
        out += [f"mp{i} a{i} {a} vdd vdd pch W='wp' L='l'", f"mn{i} a{i} {a} 0 0 nch W='wn' L='l'",
                f"r{i} a{i} {b} 'r'", f"c{i} {b} 0 'c'"]
    out.append(".ends")
    # Global names differ from the subckt's: `wn={wn}` on the instance would read itself.
    names = ["pwn", "pwp", "pl", "pr", "pc"]
    if form == "monte":
        out.append(".param " + " ".join(f"{p}=agauss({v:.6g}, {0.05 * v:.6g}, 1)" for p, v in zip(names, nom)))
    else:
        out.append(".param " + " ".join(f"{p}={v:.6g}" for p, v in zip(names, nom)))
    out += [f"vdd vdd 0 {VDD}", f"vin in 0 pulse(0 {VDD} 100p 20p 20p 1.5n 4n)",
            "x1 in out vdd chain wn='pwn' wp='pwp' l='pl' r='pr' c='pc'"]
    tran = f".tran {tstep} {tstop}"
    if form == "data":
        out.append(".data pts " + " ".join(names))
        out += ["+ " + " ".join(f"{v:.6g}" for v in row(k)) for k in range(n)]
        out += [".enddata", tran + " sweep data=pts"]
    elif form == "step":
        out += [".step param pr list " + " ".join(f"{row(k)[3]:.6g}" for k in range(n)), tran]
    elif form == "monte":
        out += [".option seed=1", tran + f" sweep monte={n}"]
    else:
        out += [".step temp list " + " ".join(f"{-40 + 165 * k / max(n - 1, 1):.4g}" for k in range(n)), tran]
    lo, mid, hi = 0.1 * VDD, 0.5 * VDD, 0.9 * VDD
    out += [f".meas tran tpd trig v(in) val={mid:g} rise=1 targ v(out) val={mid:g} fall=1",
            f".meas tran tfall trig v(out) val={hi:g} fall=1 targ v(out) val={lo:g} fall=1",
            f".meas tran trise trig v(out) val={lo:g} rise=1 targ v(out) val={hi:g} rise=1",
            ".end", ""]
    return "\n".join(out)


def selftest():
    d = deck("data", 4)
    assert d.count("\n+ ") >= 4 and "sweep data=pts" in d and d.count("\nx") == 1
    assert row(3) == row(3) and row(3) != row(4)
    for f in ("step", "monte", "temp"):
        assert ".meas tran tpd" in deck(f, 3)
    print("selftest ok")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--form", choices=["data", "step", "monte", "temp"], default="data")
    ap.add_argument("-n", type=int, default=1000)
    ap.add_argument("--stages", type=int, default=5)
    ap.add_argument("--tstep", default="1p")
    ap.add_argument("--tstop", default="4n", help="short runs isolate per-point overhead")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
    else:
        sys.stdout.write(deck(a.form, a.n, a.stages, a.tstep, a.tstop))
