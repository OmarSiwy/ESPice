#!/usr/bin/env python3
"""Ensemble proxy decks for dev/research/gpu-ensemble.md (#99).

A real ensemble shares one pattern across N points. Until it exists, the
proxy is a stacked deck: N electrically independent copies of one circuit
in one netlist, each with its own sources and its own model cards, so the
matrix is block diagonal and the existing GPU eval and device LU batch the
points as instances. `single_<k>.sp` is copy k alone, the per-point CPU run.

  gen.py DIR MODEL CIRCUIT ENSEMBLE ANALYSIS N
    MODEL     bsim3 (LEVEL=49) | psp103 (LEVEL=1040); both GPU-resident at
              f8998e0, where BSIM4 still stays on the host (#93)
    CIRCUIT   ota (5T OTA follower) | chain50 (50 inverters) |
              chains10 (ten 50-inverter chains off one input)
    ENSEMBLE  mc (seeded threshold and mobility draws per point) |
              cj (5 corners x 11 Jacobian points; N is ignored, 55 points)
    ANALYSIS  op | tran
  gen.py --selftest
"""
import os
import random
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
# tt, ff, ss, fs, sf: (dVth n, mobility scale n, dVth p, mobility scale p).
CORNERS = [(0, 1, 0, 1), (-0.03, 1.1, -0.03, 1.1), (0.03, 0.9, 0.03, 0.9),
           (-0.03, 1.1, 0.03, 0.9), (0.03, 0.9, -0.03, 1.1)]
N_DESIGN = 5   # design parameters: W multipliers of five device groups
H = 0.02       # Jacobian step, relative


def psp_card(kind):
    """stress/vacask_ring.sp's PSP103 card for `kind` (n or p), one line."""
    text = open(f"{ROOT}/tests/fixtures/stress/vacask_ring.sp").read()
    m = re.search(rf"\.model psp103{kind} \w+\(level=1040\n((?:\+.*\n)+)", text)
    return " ".join(l[1:].strip() for l in m.group(1).splitlines()).rstrip(")").strip()


TECH = {
    "bsim3": dict(vdd=1.8, l=0.18, wn=0.6, wp=1.2),
    "psp103": dict(vdd=1.2, l=0.2, wn=1.0, wp=2.0),
}


def cards(model, s, dv_n, mu_n, dv_p, mu_p):
    if model == "bsim3":
        return [f".model nch{s} NMOS(LEVEL=49 VTH0={0.4 + dv_n:.6g} U0={670 * mu_n:.6g})",
                f".model pch{s} PMOS(LEVEL=49 VTH0={-0.4 - dv_p:.6g} U0={250 * mu_p:.6g})"]
    out = []
    for kind, typ, dv, mu in (("n", "NMOS", dv_n, mu_n), ("p", "PMOS", dv_p, mu_p)):
        body = psp_card(kind)
        body = re.sub(r"\bvfbo=\S+", f"vfbo={-1.1 + dv:.6g}", body)
        body = re.sub(r"\buo=\S+", f"uo={3.5e-2 * mu:.6g}", body)
        out.append(f".model {kind}ch{s} {typ}(level=1040 {body})")
    return out


def points(ensemble, n, seed=1):
    """Per point: ((dVth n, mu n, dVth p, mu p), five W multipliers)."""
    if ensemble == "cj":
        jac = [[1.0] * N_DESIGN]
        for i in range(N_DESIGN):
            for sgn in (1 + H, 1 - H):
                w = [1.0] * N_DESIGN
                w[i] = sgn
                jac.append(w)
        return [(c, w) for c in CORNERS for w in jac]
    rng = random.Random(seed)
    return [((rng.gauss(0, 0.01), rng.gauss(1, 0.03), rng.gauss(0, 0.01), rng.gauss(1, 0.03)),
             [1.0] * N_DESIGN) for _ in range(n)]


def copy(model, circuit, analysis, k, pt):
    """Copy k's elements, every node and model suffixed `_k`."""
    t = TECH[model]
    var, w = pt
    s = f"_{k}"
    out = cards(model, s, *var) + [f"Vdd{s} vdd{s} 0 DC {t['vdd']}"]

    def node(x):
        return x if x == "0" else x + s

    def m(name, d, g, src, b, typ, wu):
        out.append(f"M{name}{s} {node(d)} {node(g)} {node(src)} {node(b)} {typ}{s} W={wu:.6g}u L={t['l']}u")
    half = t["vdd"] / 2
    if circuit == "ota":
        # 5T OTA as a unity-gain follower around vdd/2.
        step = f"PULSE({half - 0.05:g} {half + 0.05:g} 1n 0.1n 0.1n 5n 10n)" if analysis == "tran" else ""
        out.append(f"Vin{s} in{s} 0 DC {half:g} {step}")
        out.append(f"Vb{s} vb{s} 0 DC {0.4 * t['vdd']:.6g}")
        m("1", "d1", "in", "tail", "0", "nch", 4 * t["wn"] * w[0])
        m("2", "out", "out", "tail", "0", "nch", 4 * t["wn"] * w[0])
        m("3", "d1", "d1", "vdd", "vdd", "pch", 4 * t["wp"] * w[1])
        m("4", "out", "d1", "vdd", "vdd", "pch", 4 * t["wp"] * w[1])
        m("5", "tail", "vb", "0", "0", "nch", 8 * t["wn"] * w[2])
        out.append(f"Cl{s} out{s} 0 {50 * w[3]:.6g}f")
        out.append(f"Rl{s} out{s} 0 {100 * w[4]:.6g}k")
    else:
        # A single 500-stage chain's OP fails every rung, hence ten of 50.
        step = f"PULSE(0 {t['vdd']} 0.1n 20p 20p 1n 2n)" if analysis == "tran" else ""
        out.append(f"Vin{s} a0{s} 0 DC 0 {step}")
        for c in range(1 if circuit == "chain50" else 10):
            for i in range(50):
                g = w[i % N_DESIGN]
                a, y = ("a0" if i == 0 else f"c{c}a{i}"), f"c{c}a{i + 1}"
                m(f"p{c}_{i}", y, a, "vdd", "vdd", "pch", t["wp"] * g)
                m(f"n{c}_{i}", y, a, "0", "0", "nch", t["wn"] * g)
                out.append(f"C{c}_{i}{s} {node(y)} 0 1f")
    return out


def deck(model, circuit, analysis, pts, first=0):
    body = [f"* ensemble proxy: {model} {circuit} x {len(pts)} ({analysis})"]
    for k, pt in enumerate(pts, first):
        body += copy(model, circuit, analysis, k, pt)
    # tmax is a tenth of the run, so the LTE, not tstep, sets every step.
    stop = 20 if circuit == "ota" else 4
    body.append(".op" if analysis == "op" else f".tran 10p {stop}n 0 {stop / 10:g}n")
    body.append(".end")
    return "\n".join(body) + "\n"


def write(d, model, circuit, ensemble, analysis, n):
    os.makedirs(d, exist_ok=True)
    pts = points(ensemble, n)
    with open(f"{d}/stacked.sp", "w") as f:
        f.write(deck(model, circuit, analysis, pts))
    for k, pt in enumerate(pts):
        with open(f"{d}/single_{k}.sp", "w") as f:
            f.write(deck(model, circuit, analysis, [pt], k))
    return len(pts)


def selftest():
    cj = points("cj", 0)
    assert len(cj) == 55
    assert cj[0][1] == [1.0] * 5 and cj[1][1][0] == 1 + H and cj[2][1][0] == 1 - H
    assert points("mc", 8) == points("mc", 8)  # seeded
    for model in TECH:
        one = deck(model, "ota", "op", cj[:1])
        two = deck(model, "ota", "op", cj[:2])
        assert one.count("\nM") == 5 and two.count("\nM") == 10
        assert two.count(".model") == 4
        assert deck(model, "chain50", "tran", cj[:1]).count("\nM") == 100
        assert deck(model, "chains10", "op", cj[:2]).count("\nM") == 2000
    assert "vfbo=-1.07" in deck("psp103", "ota", "op", cj[22:23])  # ss: +0.03
    print("gen.py selftest: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    else:
        d, model, circuit, ensemble, analysis, n = sys.argv[1:]
        print(write(d, model, circuit, ensemble, analysis, int(n)))
