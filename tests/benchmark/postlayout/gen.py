#!/usr/bin/env python3
"""Synthetic post-layout decks for `zig build bench-postlayout`.

Each deck looks like a DSPF/SPEF back-annotation flattened to SPICE: standard
cells as subcircuits, every signal net split into pi segments (one R per
segment, one ground C per node) from the driver pin through each load pin,
coupling caps between neighbouring nets, and the vdd/vss rails extracted as
a mesh (row rails plus vertical straps). Families:

  chain  parallel 50-stage inverter chains off one clock net
  ring   enable-gated 31-stage ring oscillators (NAND2 + 30 INV)
  logic  a levelized random NAND2/NOR2/INV block driven by clocks
  sram   6T array: flash write through all wordlines, precharge, read row 0

`bsim4` decks (LEVEL=54) run in espice, ngspice and VACASK; `psp103`
(LEVEL=1040) in espice and VACASK only, since ngspice-45 has no PSP.
Output is deterministic in (family, model, size, seed).

  gen.py DIR                  the default suite into DIR
  gen.py DIR chain bsim4 10k  one deck
  gen.py --selftest
"""
import math
import random
import sys

TECH = {
    # vdd, L, Wn, Wp, and the model cards. The BSIM4 card is the corpus's
    # (dc/device_bsim4_*.sp); the PSP103 one is stress/vacask_ring's.
    "bsim4": dict(vdd=1.0, l=0.1, wn=0.4, wp=0.8, cards="""\
.model nch NMOS(LEVEL=54 TOXE=1.8e-9 TOXP=1.5e-9 TOXM=1.8e-9 VTH0=0.3 K1=0.5 K2=-0.1 VSAT=1.5e5 U0=300 UA=1e-9 UB=1e-18 UC=-4.6e-11 RDSW=200 NFACTOR=1.5 VOFF=-0.1 CDSC=0 CDSCD=0)
.model pch PMOS(LEVEL=54 TOXE=1.8e-9 TOXP=1.5e-9 TOXM=1.8e-9 VTH0=-0.35 K1=0.5 K2=-0.1 VSAT=1.2e5 U0=100 RDSW=400)
"""),
    "psp103": dict(vdd=1.2, l=0.2, wn=1.0, wp=2.0, cards=None),
}

# Extraction constants: ohm and fF per um of route, via ohms, rail values.
R_UM, C_UM, CC_UM, R_VIA = 0.9, 0.12, 0.04, 2.0
R_RAIL, C_RAIL, R_STRAP, R_PAD, STRAP_PITCH = 0.3, 0.3, 0.2, 0.5, 16


def psp_cards(root):
    """The two PSP103 .model cards of stress/vacask_ring.sp."""
    text = open(f"{root}/tests/fixtures/stress/vacask_ring.sp").read()
    out, keep = [], False
    for line in text.splitlines():
        if line.lower().startswith(".model"):
            keep = True
        elif not line.startswith("+"):
            keep = False
        if keep:
            out.append(line)
    return "\n".join(out).replace("psp103n", "nch").replace("psp103p", "pch") + "\n"


class Deck:
    def __init__(self, model, seed, root):
        self.t = dict(TECH[model])
        if self.t["cards"] is None:
            self.t["cards"] = psp_cards(root)
        self.rng = random.Random(seed)
        self.lines = []      # instances and parasitics
        self.nets = []       # (name, pins) in placement order; pin 0 drives
        self.nt = 0          # transistors
        self.nr = self.nc = 0

    def cells(self):
        t = self.t
        l, wn, wp = t["l"], t["wn"], t["wp"]

        def m(name, d, g, s, b, typ, w):
            # Diffusion extends 0.25 um past the gate: AD/AS/PD/PS as extracted.
            return f"{name} {d} {g} {s} {b} {typ} W={w:g}u L={l:g}u AD={w*0.25:g}p AS={w*0.25:g}p PD={2*w+0.5:g}u PS={2*w+0.5:g}u"
        return "\n".join([
            ".subckt inv a y vdd vss",
            m("mp", "y", "a", "vdd", "vdd", "pch", wp),
            m("mn", "y", "a", "vss", "vss", "nch", wn),
            ".ends",
            ".subckt inv8 a y vdd vss",
            m("mp", "y", "a", "vdd", "vdd", "pch", 8 * wp),
            m("mn", "y", "a", "vss", "vss", "nch", 8 * wn),
            ".ends",
            ".subckt nand2 a b y vdd vss",
            m("mp1", "y", "a", "vdd", "vdd", "pch", wp),
            m("mp2", "y", "b", "vdd", "vdd", "pch", wp),
            m("mn1", "y", "a", "x", "vss", "nch", 2 * wn),
            m("mn2", "x", "b", "vss", "vss", "nch", 2 * wn),
            ".ends",
            ".subckt nor2 a b y vdd vss",
            m("mp1", "x", "a", "vdd", "vdd", "pch", 2 * wp),
            m("mp2", "y", "b", "x", "vdd", "pch", 2 * wp),
            m("mn1", "y", "a", "vss", "vss", "nch", wn),
            m("mn2", "y", "b", "vss", "vss", "nch", wn),
            ".ends",
            # 6T bitcell: weak pull-ups, pass gates between.
            ".subckt bit6t bl blb wl vdd vss",
            m("mu1", "q", "qb", "vdd", "vdd", "pch", wp / 2),
            m("md1", "q", "qb", "vss", "vss", "nch", 1.5 * wn),
            m("mu2", "qb", "q", "vdd", "vdd", "pch", wp / 2),
            m("md2", "qb", "q", "vss", "vss", "nch", 1.5 * wn),
            m("mg1", "bl", "wl", "q", "vss", "nch", wn),
            m("mg2", "blb", "wl", "qb", "vss", "nch", wn),
            ".ends",
            # Precharge and equalize (3 PMOS), bitline write pull-down (1 NMOS).
            ".subckt pre bl blb pb vdd",
            m("mp1", "bl", "pb", "vdd", "vdd", "pch", 4 * wp),
            m("mp2", "blb", "pb", "vdd", "vdd", "pch", 4 * wp),
            m("mp3", "bl", "pb", "blb", "vdd", "pch", 2 * wp),
            ".ends",
            ".subckt wdrv bl we vss",
            m("mn", "bl", "we", "vss", "vss", "nch", 32 * wn),
            ".ends",
        ]) + "\n"

    CELL_T = {"inv": 2, "inv8": 2, "nand2": 4, "nor2": 4, "bit6t": 6, "pre": 3, "wdrv": 1}

    def inst(self, name, cell, pins):
        self.nt += self.CELL_T[cell]
        self.lines.append(f"X{name} {' '.join(pins)} {cell}")

    def net(self, name, nloads, seg):
        """A routed net with a driver pin and `nloads` load pins. Returns the
        pin node names (driver first); parasitics are emitted by `extract`."""
        pins = [f"{name}_{k * seg}" for k in range(nloads + 1)]
        self.nets.append((name, nloads * seg))
        return pins

    def extract(self):
        """Pi-segment RC for every net, ground C lumped per node, and coupling
        caps to the next net in placement order, node for node."""
        out = self.lines
        for i, (name, nseg) in enumerate(self.nets):
            cnode = [0.0] * (nseg + 1)
            for k in range(nseg):
                um = self.rng.uniform(0.5, 4.0)
                r = um * R_UM + (R_VIA if k == 0 else 0.0)
                out.append(f"R{name}_{k} {name}_{k} {name}_{k + 1} {r:.4g}")
                cnode[k] += um * C_UM / 2
                cnode[k + 1] += um * C_UM / 2
            for k, c in enumerate(cnode):
                out.append(f"C{name}_{k} {name}_{k} 0 {c:.4g}f")
            self.nr += nseg
            self.nc += nseg + 1
            if i + 1 < len(self.nets):
                other, oseg = self.nets[i + 1]
                for k in range(0, min(nseg, oseg) + 1, 2):
                    out.append(f"CC{name}_{k} {name}_{k} {other}_{k} {self.rng.uniform(0.5, 4.0) * CC_UM:.4g}f")
                    self.nc += 1

    def rails(self, rows, cols):
        """vdd/vss meshes: per-row rails tapped at every cell, vertical straps
        every STRAP_PITCH cells, pads on both ends of the top row. Returns the
        (vdd, vss) pin of cell (row, col)."""
        for rail, pad in (("vd", "vdd"), ("vs", "0")):
            for r in range(rows):
                for c in range(cols):
                    self.lines.append(f"R{rail}{r}_{c} {rail}{r}_{c} {rail}{r}_{c + 1} {R_RAIL}")
                    self.lines.append(f"C{rail}{r}_{c} {rail}{r}_{c} 0 {C_RAIL}f")
                    self.nr += 1
                    self.nc += 1
                for c in range(0, cols + 1, STRAP_PITCH):
                    if r + 1 < rows:
                        self.lines.append(f"R{rail}s{r}_{c} {rail}{r}_{c} {rail}{r + 1}_{c} {R_STRAP}")
                        self.nr += 1
            for c in (0, cols):
                self.lines.append(f"R{rail}p{c} {pad} {rail}0_{c} {R_PAD}")
                self.nr += 1
        return lambda r, c: (f"vd{r}_{c}", f"vs{r}_{c}")

    def placement(self, ncells):
        cols = max(STRAP_PITCH, int(math.sqrt(ncells * 4)) // STRAP_PITCH * STRAP_PITCH)
        rows = -(-ncells // cols)
        rail = self.rails(rows, cols)
        return lambda i: rail(i // cols, i % cols)

    def render(self, title, sources, tran, saves):
        t = self.t
        return "".join([
            f"* {title}\n",
            f"* Generated by tests/benchmark/postlayout/gen.py: {self.nt} transistors, "
            f"{self.nr} R, {self.nc} C. Synthetic extraction, no oracle.\n",
            t["cards"], self.cells(),
            f"Vdd vdd 0 DC {t['vdd']}\n",
            *[s + "\n" for s in sources],
            *[s + "\n" for s in self.lines],
            f".save {' '.join(f'v({n})' for n in saves)}\n",
            f".tran {tran}\n.end\n",
        ])


def window(size, ps):
    """`.tran` card: a 2 ps step cap, and a stop time cut 2x at 10k and 5x
    at 100k so one benchmark pass stays in minutes. The SRAM keeps its 1 ns
    write/precharge/read sequence."""
    return f"2p {ps // (1 if size < 5000 else 2 if size < 50000 else 5)}p"


def pulse(vdd, delay, width, period):
    return f"PULSE(0 {vdd} {delay}p 20p 20p {width}p {period}p)"


def chain(d, size):
    stages = 50
    n = max(1, size // (2 * stages))
    place = d.placement(n * stages)
    clk = d.net("clk", n, 2)
    saves = []
    for c in range(n):
        inp = clk[c + 1]
        for s in range(stages):
            pins = d.net(f"c{c}s{s}", 0 if s == stages - 1 else 1, 6)
            d.inst(f"c{c}s{s}", "inv", [inp, pins[0], *place(c * stages + s)])
            inp = pins[-1]
            if c in (0, n - 1) and s in (9, 24, 49):
                saves.append(pins[0])
    return [f"Vclk clk_0 0 {pulse(d.t['vdd'], 20, 230, 500)}"], window(size, 1000), saves


def ring(d, size):
    stages = 31
    n = max(1, size // (2 * stages + 2))
    place = d.placement(n * stages)
    en = d.net("en", n, 2)
    saves = []
    for g in range(n):
        pins = [d.net(f"r{g}s{s}", 1, 6) for s in range(stages)]
        d.inst(f"r{g}s0", "nand2", [en[g + 1], pins[-1][1], pins[0][0], *place(g * stages)])
        for s in range(1, stages):
            d.inst(f"r{g}s{s}", "inv", [pins[s - 1][1], pins[s][0], *place(g * stages + s)])
        if g in (0, n - 1):
            saves += [pins[0][0], pins[stages // 2][0]]
    return [f"Ven en_0 0 {pulse(d.t['vdd'], 50, 5000, 10000)}"], window(size, 2000), saves


def logic(d, size):
    ngates = max(8, int(size / 3.3))
    # Twelve levels, a pipeline stage's depth. At depth 41 (width sqrt(2n))
    # the 10k block's operating point stalled in the gmin ladder for 80 min.
    levels = min(12, max(2, ngates // 8))
    width = -(-ngates // levels)
    rng = d.rng
    kinds = [[rng.choice(("inv", "nand2", "nand2", "nor2")) for _ in range(width)] for _ in range(levels)]
    # Fanin: gate (l, j) reads (l-1, j +- 3); the second input reaches back
    # one or two levels. Level 0 reads the primary inputs.
    fanin = [[[(l - 1, min(width - 1, max(0, j + rng.randint(-3, 3))))]
              + ([(max(-1, l - rng.choice((1, 2))), min(width - 1, max(0, j + rng.randint(-3, 3))))] if kinds[l][j] != "inv" else [])
              for j in range(width)] for l in range(levels)]
    loads = {}
    for l in range(levels):
        for j in range(width):
            for src in fanin[l][j]:
                loads.setdefault(src, []).append((l, j))
    pin = {}
    sources = []
    for j in range(width):
        name = f"pi{j}"
        pins = d.net(name, len(loads.get((-1, j), [])), 5)
        period = 200 * (1 + j % 5)
        sources.append(f"V{name} {pins[0]} 0 {pulse(d.t['vdd'], 10 * (j % 7) + 20, period / 2 - 20, period)}")
        for k, dst in enumerate(loads.get((-1, j), [])):
            pin[((-1, j), dst)] = pins[k + 1]
    place = d.placement(levels * width)
    outs = {}
    for l in range(levels):
        for j in range(width):
            pins = d.net(f"g{l}_{j}", len(loads.get((l, j), [])), 5)
            outs[(l, j)] = pins[0]
            for k, dst in enumerate(loads.get((l, j), [])):
                pin[((l, j), dst)] = pins[k + 1]
    for l in range(levels):
        for j in range(width):
            ins = [pin[(src, (l, j))] for src in fanin[l][j]]
            d.inst(f"g{l}_{j}", kinds[l][j], [*ins, outs[(l, j)], *place(l * width + j)])
    saves = [outs[(levels - 1, j)] for j in range(min(width, 8))]
    return sources, window(size, 1000), saves


def sram(d, size):
    rows = min(256, max(16, 2 ** round(math.log2(math.sqrt(size / 6) * 1.4))))
    cols = max(2, size // (6 * rows))
    vdd = d.t["vdd"]
    rail = d.rails(rows + 1, cols)
    # Wordlines: row 0 is on for the flash write and again for the read.
    sources = [f"Vwb0 wb0 0 PULSE(0 {vdd} 300p 20p 20p 300p 600p)",
               f"Vwb wb 0 PULSE(0 {vdd} 300p 20p 20p 10n 20n)",
               f"Vwe we 0 PULSE({vdd} 0 300p 20p 20p 10n 20n)",
               f"Vpb pb 0 PULSE({vdd} 0 280p 20p 20p 320p 10n)"]
    wl = []
    for r in range(rows):
        pins = d.net(f"wl{r}", cols, 2)
        d.inst(f"wd{r}", "inv8", ["wb0" if r == 0 else "wb", pins[0], *rail(r, 0)])
        wl.append(pins)
    saves = [wl[0][-1]]
    for c in range(cols):
        bl = d.net(f"bl{c}", rows + 1, 2)
        blb = d.net(f"blb{c}", rows + 1, 2)
        for r in range(rows):
            d.inst(f"b{r}_{c}", "bit6t", [bl[r + 1], blb[r + 1], wl[r][c + 1], *rail(r, c)])
        vdd_pin, vss_pin = rail(rows, c)
        d.inst(f"p{c}", "pre", [bl[0], blb[0], "pb", vdd_pin])
        # Alternate the written value column by column.
        d.inst(f"w{c}", "wdrv", [(bl if c % 2 == 0 else blb)[-1], "we", vss_pin])
        if c < 4:
            saves += [bl[0], blb[0]]
    return sources, "2p 1n", saves


FAMILIES = {"chain": chain, "ring": ring, "logic": logic, "sram": sram}
# No 100k logic block or SRAM: their LU grows past what a benchmark run can
# factor a few thousand times (the 100k SRAM: 16.6x fill, 3.5e9
# multiply-adds a refactor). `gen.py DIR sram bsim4 100k` still writes one.
SUITE = [(f, m, s) for m, sizes in (("bsim4", ("1k", "10k", "100k")), ("psp103", ("1k", "10k")))
         for f in FAMILIES for s in sizes if (f, s) not in (("logic", "100k"), ("sram", "100k"))]


def generate(root, family, model, size, seed=1):
    n = int(float(size[:-1]) * 1000) if size.endswith("k") else int(size)
    d = Deck(model, seed, root)
    sources, tran, saves = FAMILIES[family](d, n)
    d.extract()
    title = f"postlayout {family} {model} {size}"
    return d.render(title, sources, tran, saves), d


def selftest(root):
    a, d = generate(root, "logic", "bsim4", "1k")
    b, _ = generate(root, "logic", "bsim4", "1k")
    assert a == b, "not deterministic"
    for fam in FAMILIES:
        text, d = generate(root, fam, "bsim4", "1k")
        assert 800 <= d.nt <= 1300, (fam, d.nt)
        assert d.nr + d.nc >= 3 * d.nt, (fam, d.nr + d.nc, d.nt)
        nodes = set()
        for line in text.splitlines():
            if line[:1] in "RC":
                nodes.update(line.split()[1:3])
        for line in text.splitlines():
            if line.startswith(".save"):
                for v in line.split()[1:]:
                    assert v[2:-1] in nodes, (fam, v)
    print("selftest ok")


def main(argv):
    import os
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    if argv[1:] == ["--selftest"]:
        return selftest(root)
    out = argv[1]
    os.makedirs(out, exist_ok=True)
    for fam, model, size in [tuple(argv[2:5])] if len(argv) == 5 else SUITE:
        text, d = generate(root, fam, model, size)
        path = f"{out}/{fam}_{model}_{size}.sp"
        with open(path, "w") as f:
            f.write(text)
        print(f"{path}: {d.nt} transistors, {d.nr} R, {d.nc} C")


if __name__ == "__main__":
    main(sys.argv)
