"""Plot `zig build bench` medians against circuit size, per simulator.

    nix develop .#benchmarking --command python3 tools/bench_plot.py \
        [zig-out/benchmark-results.md] [tests/fixtures] [zig-out/bench-plots]

Writes all.png (every fixture) and one <analysis>.png per analysis type.
For `zig build bench-postlayout` output, pass zig-out/postlayout-results.md
and zig-out/postlayout; groups are then family_model (chain_bsim4, ...).
x is the device count after subcircuit expansion, y the median wall time;
both axes log. The analysis comes from the deck's .expected.json, else
its top-level directory.
"""
import json, re, sys
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

report = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/benchmark-results.md")
fixtures = Path(sys.argv[2] if len(sys.argv) > 2 else "tests/fixtures")
out = Path(sys.argv[3] if len(sys.argv) > 3 else "zig-out/bench-plots")


def devices(deck: Path) -> int:
    """Device count with X instances expanded through their .subckt bodies.
    ponytail: ignores .include/.lib and params on X lines; follow includes
    if those decks matter."""
    lines, body, name = [], defaultdict(list), None
    for raw in deck.read_text(errors="replace").splitlines():
        s = raw.strip()
        if not s or s[0] in "*+;$":
            continue
        word = s.split()[0].lower()
        if word == ".subckt":
            name = s.split()[1].lower()
        elif word == ".ends":
            name = None
        elif s[0] != ".":
            (body[name] if name else lines).append(s.split())

    memo = {}

    def count(items, seen=()):
        n = 0
        for tok in items:
            if tok[0][0] in "xX":
                # Subckt name is the last token that is not key=value.
                sub = next((t.lower() for t in reversed(tok[1:]) if "=" not in t), None)
                if sub in body and sub not in seen:
                    if sub not in memo:
                        memo[sub] = count(body[sub], seen + (sub,))
                    n += memo[sub]
                    continue
            n += 1
        return n

    return max(count(lines), 1)


def analysis(rel: str) -> str:
    exp = (fixtures / rel).with_suffix(".expected.json")
    try:
        a = json.loads(exp.read_text())["analysis"]
        return "+".join(a) if isinstance(a, list) else a
    except (OSError, KeyError, ValueError):
        # Corpus decks: their directory. Post-layout decks (fam_model_size.sp,
        # no oracle): fam_model.
        return rel.split("/")[0] if "/" in rel else rel.rsplit("_", 1)[0]


header, rows = None, []
for line in report.read_text().splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if cells[0] == "Fixture":
        header = [c.removesuffix(" ms") for c in cells if c.endswith(" ms")]
    elif header and line.startswith("| ") and not line.startswith("|---"):
        times = [float(c) if re.fullmatch(r"[\d.]+", c) else None for c in cells[1 : 1 + len(header)]]
        rows.append((cells[0], times))
if not rows:
    sys.exit(f"no rows in {report}")

points = []  # (analysis, size, times)
for rel, times in rows:
    deck = fixtures / rel
    if deck.exists():
        points.append((analysis(rel), devices(deck), times))

out.mkdir(parents=True, exist_ok=True)


def plot(name, pts):
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for i, sim in enumerate(header):
        xy = sorted((s, t[i]) for _, s, t in pts if t[i] is not None)
        if xy:
            ax.plot(*zip(*xy), marker="o", ms=4, ls="none", alpha=0.6, label=f"{sim} ({len(xy)})")
    ax.set(xscale="log", yscale="log", xlabel="devices (subcircuits expanded)",
           ylabel="median wall time, ms", title=f"{name}: {len(pts)} decks")
    ax.grid(True, which="both", alpha=0.3)
    if ax.lines:
        ax.legend()
    fig.tight_layout()
    fig.savefig(out / f"{name}.png", dpi=130)
    plt.close(fig)


plot("all", points)
groups = defaultdict(list)
for p in points:
    groups[p[0]].append(p)
for name, pts in sorted(groups.items()):
    plot(name, pts)
print(f"{len(points)} decks, {len(groups)} analyses -> {out}/")
