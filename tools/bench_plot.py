"""Plot `zig build bench` medians against circuit size, per simulator.

    nix develop .#benchmarking --command python3 tools/bench_plot.py \
        [zig-out/benchmark-results.md] [tests/fixtures] [zig-out/bench-plots]

Writes all.png (every fixture), one <analysis>.png per analysis type, and
summary.md: the speedup and agreement table per reference simulator and the
largest decks, which the docs Benchmarks page includes as written.
For `zig build bench-postlayout` output, pass zig-out/postlayout-results.md
and zig-out/postlayout; groups are then family_model (chain_bsim4, ...).
x is the device count after subcircuit expansion, y the median wall time;
both axes log. The analysis comes from the deck's .expected.json, else
its top-level directory.
Reference-adapter columns are dropped unless `--vendor` is given.
Also writes headline.svg: per-deck speedups with the average per decade of size.
`--readme README.md` rewrites that file's <!-- bench:start/end --> block
with headline.svg, the speedup table and where the numbers were measured
(.github/workflows/bench.yml does this on every release).
"""
import json, math, re, sys
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker

vendor = "--vendor" in sys.argv
argv = [a for a in sys.argv if a != "--vendor"]
readme = None
if "--readme" in argv:
    i = argv.index("--readme")
    readme = Path(argv[i + 1])
    del argv[i : i + 2]
report = Path(argv[1] if len(argv) > 1 else "zig-out/benchmark-results.md")
fixtures = Path(argv[2] if len(argv) > 2 else "tests/fixtures")
out = Path(argv[3] if len(argv) > 3 else "zig-out/bench-plots")


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


header, rows, verdict_cols, verdicts = None, [], [], {}
for line in report.read_text().splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if cells[0] == "Fixture":
        header = [c.removesuffix(" ms") for c in cells if c.endswith(" ms")]
        verdict_cols = cells[1 + len(header) :]
    elif header and line.startswith("| ") and not line.startswith("|---"):
        times = [float(c) if re.fullmatch(r"[\d.]+", c) else None for c in cells[1 : 1 + len(header)]]
        rows.append((cells[0], times))
        verdicts[cells[0]] = dict(zip(verdict_cols, cells[1 + len(header) :]))
if not rows:
    sys.exit(f"no rows in {report}")
if not vendor:
    keep = [i for i, h in enumerate(header) if not re.match(r"(HSPICE|Spectre)\b", h)]
    header = [header[i] for i in keep]
    rows = [(rel, [t[i] for i in keep]) for rel, t in rows]

points = []  # (analysis, size, times)
rows_used = []
for rel, times in rows:
    deck = fixtures / rel
    if deck.exists():
        points.append((analysis(rel), devices(deck), times))
        rows_used.append((rel, times))

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


def speedup(pts):
    """Reference time over espice time per deck: above 1, espice is faster."""
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for i, sim in enumerate(header[1:], 1):
        xy = sorted((s, t[i] / t[0]) for _, s, t in pts if t[0] and t[i])
        if xy:
            ax.plot(*zip(*xy), marker="o", ms=4, ls="none", alpha=0.6, label=f"{sim} / espice ({len(xy)})")
    ax.axhline(1, color="k", lw=0.8)
    ax.set(xscale="log", yscale="log", xlabel="devices (subcircuits expanded)",
           ylabel="speedup (reference ms / espice ms)", title="espice speedup: above 1 is faster")
    ax.grid(True, which="both", alpha=0.3)
    if ax.lines:
        ax.legend()
    fig.tight_layout()
    fig.savefig(out / "speedup.png", dpi=130)
    plt.close(fig)


def bars(pts):
    """One group of bars per deck, smallest first; for short reports."""
    rows = sorted(zip(pts, [r for r, _ in rows_used]), key=lambda pr: pr[0][1])
    fig, ax = plt.subplots(figsize=(max(9, 0.6 * len(rows)), 5.5))
    w = 0.8 / len(header)
    for i, sim in enumerate(header):
        ax.bar([k + i * w for k in range(len(rows))], [p[2][i] or 0 for p, _ in rows], w, label=sim)
    ax.set_xticks([k + 0.4 - w / 2 for k in range(len(rows))], [r.removesuffix(".sp") for _, r in rows], rotation=60, ha="right")
    ax.set(yscale="log", ylabel="median wall time, ms (missing bar: did not finish)", title="post-layout decks")
    ax.grid(True, axis="y", which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out / "bars.png", dpi=130)
    plt.close(fig)


def median(xs):
    xs, mid = sorted(xs), len(xs) // 2
    return xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2


def headline(pts):
    """headline.svg: every deck's speedup as a faint dot, and per reference
    simulator its average (geometric mean, the right mean for ratios) per
    decade of device count as a line. Transparent, grey text: it reads on
    light and dark pages."""
    with plt.rc_context({"svg.fonttype": "none", "font.size": 11, "text.color": "#777",
                         "axes.labelcolor": "#777", "xtick.color": "#777", "ytick.color": "#777"}):
        fig, ax = plt.subplots(figsize=(8, 4.2))
        for i, sim in enumerate(header[1:], 1):
            xy = [(s, t[i] / t[0]) for _, s, t in pts if t[0] and t[i]]
            if not xy:
                continue
            dots = ax.scatter(*zip(*xy), s=8, alpha=0.18, linewidths=0)
            decades = defaultdict(list)
            for s, r in xy:
                decades[int(math.log10(s))].append((s, r))
            line = [(math.exp(sum(math.log(s) for s, _ in v) / len(v)), math.exp(sum(math.log(r) for _, r in v) / len(v)))
                    for _, v in sorted(decades.items())]
            ax.plot(*zip(*line), marker="o", lw=2.2, color=dots.get_facecolor()[0][:3],
                    label=f"vs {sim}: {math.exp(sum(math.log(r) for _, r in xy) / len(xy)):.1f}x average, {len(xy)} decks")
        ax.axhline(1, color="#777", lw=0.8, ls="--")
        ax.set(xscale="log", yscale="log", xlabel="devices per deck (subcircuits expanded)",
               ylabel="speedup (higher is faster)")
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}x"))
        ax.set_title("ESPice speedup by circuit size", color="#777")
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            ax.spines[side].set_color("#777")
        ax.legend(frameon=False)
        fig.tight_layout()
        fig.savefig(out / "headline.svg", transparent=True)
        plt.close(fig)


def summary(pts):
    """summary.md: per reference simulator, the decks both ran, how many
    espice ran faster, the median speedup and the agree/differ verdicts;
    then the largest decks by device count."""
    lines = ["| Compared with | Decks both ran | ESPice faster | Median speedup | Agree / differ |",
             "|---|---:|---:|---:|---:|"]
    for i, sim in enumerate(header[1:], 1):
        both = [(rel, t) for rel, t in rows_used if t[0] and t[i]]
        if not both:
            continue
        ratios = sorted(t[i] / t[0] for _, t in both)
        col = next((c for c in verdict_cols if c.lower() == f"{header[0]}/{sim}".lower()), None)
        said = [verdicts[rel].get(col, "").lower() for rel, _ in both] if col else []
        lines.append(f"| {sim} | {len(both)} | {sum(r > 1 for r in ratios)} | {median(ratios):.1f}x | "
                     f"{said.count('agree')} / {said.count('differ')} |")
    lines += ["", "| Deck | Devices | " + " | ".join(f"{h} ms" for h in header) + " |",
              "|---|---:|" + "---:|" * len(header)]
    big = sorted(zip(pts, rows_used), key=lambda pr: -pr[0][1])[:8]
    for (_, size, t), (rel, _) in big:
        cells = [f"{x:,.0f}" if x is not None else "n/a" for x in t]
        lines.append(f"| `{rel}` | {size:,} | " + " | ".join(cells) + " |")
    (out / "summary.md").write_text("\n".join(lines) + "\n")


def update_readme(path):
    """Replace the <!-- bench:start --> ... <!-- bench:end --> block."""
    import os, platform, subprocess, datetime
    cpu = next((l.split(":", 1)[1].strip() for l in Path("/proc/cpuinfo").read_text().splitlines()
                if l.startswith("model name")), platform.machine())
    sha = os.environ.get("GITHUB_SHA") or subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    table = (out / "summary.md").read_text().split("\n\n")[0]
    img = os.path.relpath(out / "headline.svg", path.parent)
    block = (f"<!-- bench:start -->\n![ESPice speedup by circuit size]({img})\n\n{table}\n\n"
             f"Median of 3 runs after a warm-up, process startup included, CPU backend, {os.cpu_count()} x {cpu}, "
             f"commit `{sha[:8]}`, {datetime.date.today()}. Generated by `.github/workflows/bench.yml`.\n"
             "<!-- bench:end -->")
    text = path.read_text()
    a, b = text.index("<!-- bench:start -->"), text.index("<!-- bench:end -->") + len("<!-- bench:end -->")
    path.write_text(text[:a] + block + text[b:])


plot("all", points)
summary(points)
headline(points)
if readme:
    update_readme(readme)
speedup(points)
if len(points) <= 40:
    bars(points)
groups = defaultdict(list)
for p in points:
    groups[p[0]].append(p)
for name, pts in sorted(groups.items()):
    plot(name, pts)
print(f"{len(points)} decks, {len(groups)} analyses -> {out}/")
