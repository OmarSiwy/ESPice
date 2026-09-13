#!/usr/bin/env python3
"""Analytic small-signal oracle for docs/perf/mos1-ac-2026-09-10.md.

Solves the 5T OTA of benchmark/fixtures/sweep/opamp_wl_200 (instance 1) by
hand from ngspice's own printed gm/gds/gmbs, using ngspice's MOS1 AC stamp
(mos1acld.c:91-113, which for xnrm=1 is
  I_dp = gds(v_dp - v_sp) + gm(v_g - v_sp) + gmbs(v_b - v_sp) + gbd(v_dp - v_b)
and its SP mirror).  No simulator involved.

Point: -2.0315 and -0.7319 are BOTH faithful evaluations of this network --
of two different operating points.  Only the second one solves the DC problem.

    python3 docs/perf/mos1-ac-2026-09-10-oracle.py
"""
import cmath

# Topology, all at AC: inp = 1, inn = vdd = vbias = 0, unknowns (d1, out, tail).
#   M1 d=d1  g=inp  s=tail b=0      M2 d=out g=inn  s=tail b=0     (identical)
#   M3 d=d1  g=d1   s=vdd  b=vdd    M4 d=out g=d1   s=vdd  b=vdd   (identical)
#   M5 d=tail g=vbias s=0  b=0      -- in cutoff: gm = gds = gmbs = 0
#   Cl = 100f on out
CL = 100e-15


def solve(p, f):
    w = 2 * cmath.pi * f
    a, b, c = p["gm1"], p["gds1"], p["gmbs1"]
    A, B = p["gm3"], p["gds3"]
    gbd1, gbs1, gbd3, gbd5 = p["gbd1"], p["gbs1"], p["gbd3"], p["gbd5"]
    # M3/M4 sit with source AND bulk on vdd, so their gmbs sees v_b - v_sp = 0
    # and drops out; M1/M2's bulk is ground, so theirs does not.
    M = [
        [b + gbd1 + B + A + gbd3, 0,                          -(b + a + c)],
        [-b,                      -b,                         2 * (b + a + c + gbs1) + gbd5],
        [A,                       B + gbd3 + b + gbd1 + 1j * w * CL, -(b + a + c)],
    ]
    return _lin3(M, [-a, a, 0])


def _lin3(M, r):
    M = [row[:] for row in M]
    r = r[:]
    for i in range(3):
        q = max(range(i, 3), key=lambda k: abs(M[k][i]))
        M[i], M[q] = M[q], M[i]
        r[i], r[q] = r[q], r[i]
        for k in range(i + 1, 3):
            g = M[k][i] / M[i][i]
            for j in range(i, 3):
                M[k][j] -= g * M[i][j]
            r[k] -= g * r[i]
    x = [0j] * 3
    for i in reversed(range(3)):
        x[i] = (r[i] - sum(M[i][j] * x[j] for j in range(i + 1, 3))) / M[i][i]
    return x  # d1, out, tail


# ngspice `show` at deck defaults -- an OP that does NOT satisfy KCL to abstol
UNCONVERGED = dict(gm1=6.14609e-08, gds1=1.27607e-13, gmbs1=1.36416e-08,
                   gbd1=1e-12, gbs1=1e-12,
                   gm3=1.4306e-08, gds3=4.77626e-14, gbd3=1e-12, gbd5=1e-12)

# ngspice `show` at .options abstol=1e-18 reltol=1e-10 vntol=1e-12 -- espice
# lands on the same OP to 7 digits.
CONVERGED = dict(gm1=1.71601e-08, gds1=9.9476e-15, gmbs1=3.80863e-09,
                 gbd1=1e-12, gbs1=1e-12,
                 gm3=1.16689e-08, gds3=3.17773e-14, gbd3=1e-12, gbd5=1e-12)


def main():
    tol = 2e-5  # ngspice prints gm/gds to 6 digits; that is the floor here
    for name, p, want_d1, want_out in (
        ("unconverged OP", UNCONVERGED, -2.03154 - 0.0335846j, 26075.68 - 7531.55j),
        ("converged OP",   CONVERGED,   -0.731943 - 0.00100675j, 7676.946 - 2362.497j),
    ):
        d1, out, tail = solve(p, 1.0)
        print(f"{name:16s} f=1 Hz  v(d1_1)={d1:.7g}  v(out_1)={out:.7g}  v(tail_1)={tail:.7g}")
        assert abs(d1 - want_d1) / abs(want_d1) < tol, (name, d1, want_d1)
        assert abs(out - want_out) / abs(want_out) < tol, (name, out, want_out)
    print("ok: both simulator answers reproduced by hand from their own operating points")


if __name__ == "__main__":
    main()
