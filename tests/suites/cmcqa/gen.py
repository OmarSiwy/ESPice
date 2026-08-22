#!/usr/bin/env python3
"""CMC QA specs and the GF180MCU regression templates to ngspice-dialect decks.

  gen.py cmc QASPEC REFDIR OUT PREFIX NPN|NMOS|PMOS LEVEL|MODULE
  gen.py gf180 TESTING OUT
  gen.py selftest

cmc: one deck per qaSpec test and temperature, OUT/PREFIX_<test>[_T<t>].sp,
with OUT/<deck>.reference holding that temperature's rows of the test's
.standard file (rows: biasList outer, biasSweep, then frequency). A deck
holds one copy of the device per biasList value (DC; the biasSweep pin of
every copy hangs off the swept source vsweep through a 0 V ammeter), or
per biasList value x biasSweep value x driven pin (AC: the copy's source
on the driven pin carries ac 1). A comment above each copy names its bias.
A LEVEL selects the built-in model from `.model qamod nmos level=LEVEL`; a
MODULE (psp103tva) is an N card on `.model qamod MODULE type=1|-1`.
CMC sign conventions: I(p) = -i(v<p>_<k>), G(i,j) = Re(-i(v<i>_<k>)) of
the copy driven on j, C(i,j) = -Im(...)/w on the diagonal and +Im(...)/w
off it, V(p) = v(p_<k>) (a floating pin such as PSP's thermal node dt).
A noise test is one deck per bias point (OUT/<deck>_<n>, biasList outer,
then biasSweep), rigged as runQaTests.pl's spice.pm rigs it: hn turns the
pin's ammeter current into v(n_<p>), so N(p) (A^2/Hz) is onoise_spectrum^2.

gf180: each regression's templates rendered the way its upstream
models_regression.py renders them (geometry, temperature and corner per
foundry xlsx row), the .control block replaced by the sweep it runs.
The reference is that row's foundry block: the sweep column, then one
column per stepped bias (or the corner's column). Blocks are found by
their quantity header and the device label under it, never by column
offset. MOS Id and Rds, BJT Ic/Ib and diode I(V) are read off the .dc
output; MOS CV, BJT and diode junction capacitances are operating-point
device quantities, named on the deck's `* reference quantity:` line;
MIM/MOS capacitors are a .meas; resistors are one copy per row.
"""
import math, os, re, sys, zipfile
import xml.etree.ElementTree as ET


def spec_lines(path):
    """qaSpec lines with comments, `ifdef blocks and `include resolved.
    Includes resolve against the qaSpec's directory, as runQaTests.pl's cwd."""
    base = os.path.dirname(path)
    out, skip = [], 0
    def walk(p):
        nonlocal skip
        for raw in open(p):
            line = raw.split('//')[0].strip()
            if line.startswith('`ifdef'): skip += 1; continue
            if line.startswith('`endif'): skip -= 1; continue
            if skip or not line: continue
            if line.startswith('`include'): walk(os.path.join(base, line.split()[1])); continue
            out.append(line)
    walk(path)
    return base, out


def params(text):
    """name=value pairs from a parameter file or a modelParameters line."""
    text = re.sub(r'(?m)^\s*\+|[()]', ' ', text)  # continuation `+`, never an exponent's
    return re.findall(r'([A-Za-z_]\w*)\s*=\s*(\S+)', text)


def sweep(spec):
    a, b, s = map(float, spec.split(','))
    n = int(math.floor((b - a) / s + 1e-9))
    v = [a + i * s for i in range(n + 1)]
    if abs(v[-1] - b) > 1e-9 * abs(s):
        v.append(b)  # the reference ends on the stop value, off the step grid
    return ['%.6g' % x for x in v]


def pinval(spec):  # 'V(base)=0.3,1.05,0.02' -> ('base', '0.3,1.05,0.02')
    m = re.match(r'V\((\w+)\)=(.*)', spec)
    return m.group(1), m.group(2)


def cmc(qaspec, refdir, out, prefix, mtype, level):
    base, lines = spec_lines(qaspec)
    glob, tests, cur = {}, [], None
    for line in lines:
        key, _, rest = line.partition(' ')
        rest = rest.strip()
        if key == 'test':
            cur = {'name': rest, 'inst': [], 'model': [], 'biases': {}}
            tests.append(cur)
        elif cur is None:
            glob[key] = rest
        elif key == 'modelParameters':
            f = os.path.join(base, rest)
            cur['model'] += params(open(f).read() if os.path.isfile(f) else rest)
        elif key == 'instanceParameters':
            cur['inst'] += rest.split()
        elif key == 'biases':
            cur['biases'].update(pinval(b) for b in rest.split())
        else:
            cur[key] = rest
    pins = glob['pins'].split()
    floating = set(glob.get('float', '').split())
    letter = glob['keyLetter']
    if not level.isdigit():  # a Verilog-A module name: an N card on `.model qamod <module> type=+-1`
        letter = 'n'
    made = 0
    for t in tests:
        outs = t['outputs'].split()
        ref = os.path.join(refdir, t['name'] + '.standard')
        if not os.path.isfile(ref):
            print('cmcqa: no reference for', t['name'], file=sys.stderr)
            continue
        model = dict((k.lower(), (k, v)) for k, v in t['model'])
        model.pop('level', None); model.pop('type', None)
        head_card = '%s level=%s' % (mtype.lower(), level) if level.isdigit() else '%s type=%d' % (level, -1 if mtype == 'PMOS' else 1)
        card = '.model qamod %s\n' % head_card + ''.join('+ %s=%s\n' % kv for kv in model.values())
        sw_pin, sw = pinval(t['biasSweep']) if 'biasSweep' in t else (None, None)
        li_pin, li = pinval(t['biasList']) if 'biasList' in t else (None, '')
        lvals = li.split(',') if li_pin else [None]
        ac, noise = outs[0][0] in 'GC', outs[0][0] == 'N'
        if ac:
            drive = list(dict.fromkeys(re.match(r'\w\(\w+,(\w+)\)', o).group(1) for o in outs))
            freq = t.get('freq') or 'lin 1 %r %r' % ((1 / (2 * math.pi),) * 2)  # CMC default: omega = 1
            copies = [(l, s, d) for l in lvals for s in (sweep(sw) if sw_pin else [None]) for d in drive]
        elif noise:
            copies = [(l, s, None) for l in lvals for s in (sweep(sw) if sw_pin else [None])]
        else:
            copies = [(l, None, None) for l in lvals]
        groups = [[c] for c in copies] if noise else [copies]  # .noise runs at one operating point
        temps = t['temperature'].split()
        body = open(ref).read().strip().split('\n')
        head, rows = body[0], body[1:]
        if len(rows) % len(temps):
            print('cmcqa: %s: %d rows do not split over %d temperatures' % (t['name'], len(rows), len(temps)), file=sys.stderr)
            continue
        per = len(rows) // len(temps)
        for ti, temp in enumerate(temps):
            for gi, group in enumerate(groups):
                name = prefix + '_' + t['name'] + ('_T' + temp.replace('-', 'm').replace('.', 'p') if len(temps) > 1 else '') + \
                    ('_%d' % gi if noise else '')
                d = ['* CMC QA %s %s, T=%s C (generated by tests/suites/cmcqa/gen.py)' % (prefix, t['name'], temp),
                     '.temp %s' % temp]
                if sw_pin and not ac and not noise:
                    d.append('vsweep sw 0 dc %s' % sw.split(',')[0])
                for k, (l, s, drv) in enumerate(group):
                    d.append('* copy %d: %s' % (k, ' '.join(x for x in (
                        l and 'V(%s)=%s' % (li_pin, l), s and 'V(%s)=%s' % (sw_pin, s), drv and 'ac on %s' % drv) if x) or 'bias only'))
                    for p in pins:
                        if p in floating:
                            continue
                        if p == sw_pin and not ac and not noise:
                            d.append('v%s_%d %s_%d sw 0' % (p, k, p, k)); continue
                        v = l if p == li_pin else s if p == sw_pin else t['biases'].get(p, '0')
                        d.append('v%s_%d %s_%d 0 dc %s%s' % (p, k, p, k, v, ' ac 1' if p == drv else ''))
                    d.append(' '.join(['%s%d' % (letter, k)] + ['%s_%d' % (p, k) for p in pins] + ['qamod'] + t['inst']))
                d.append(card.rstrip())
                if noise:  # runQaTests.pl's rig: a dummy input, and the pin's ammeter current as a voltage
                    np = outs[0][2:-1]
                    d += ['vin dummy 0 0 ac 1', 'rin dummy 0 1']
                    if np in floating:
                        d.append('.noise v(%s_0) vin %s' % (np, t['freq']))
                    else:
                        d += ['hn 0 n_%s v%s_0 1' % (np, np), '.noise v(n_%s) vin %s' % (np, t['freq'])]
                elif ac:
                    d.append('.ac ' + freq)
                elif sw_pin:
                    d.append('.dc vsweep ' + sw.replace(',', ' '))
                else:
                    d.append('.op')
                d.append('.end')
                n = per // len(groups)
                open(os.path.join(out, name + '.sp'), 'w').write('\n'.join(d) + '\n')
                open(os.path.join(out, name + '.sp.reference'), 'w').write('\n'.join([head] + rows[ti * per + gi * n:ti * per + (gi + 1) * n]) + '\n')
                made += 1
    print('cmcqa: %s: %d decks' % (prefix, made), file=sys.stderr)


X = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'


def xlsx(path):
    """First sheet as a list of rows of strings (stdlib only)."""
    z = zipfile.ZipFile(path)
    ss = [''.join(t.text or '' for t in si.iter(X + 't')) for si in ET.fromstring(z.read('xl/sharedStrings.xml')).iter(X + 'si')] \
        if 'xl/sharedStrings.xml' in z.namelist() else []
    rows = []
    for r in ET.fromstring(z.read('xl/worksheets/sheet1.xml')).iter(X + 'row'):
        row = {}
        for c in r.iter(X + 'c'):
            v = c.find(X + 'v')
            if v is None:
                continue
            col = 0
            for ch in re.match(r'[A-Z]+', c.get('r')).group():
                col = col * 26 + ord(ch) - 64
            row[col - 1] = ss[int(v.text)] if c.get('t') == 's' else v.text
        rows.append([row.get(i, '') for i in range(max(row) + 1)] if row else [])
    return rows


class Block:
    """One data block of a foundry xlsx: header cells [quantity, bias,
    sweep, value...] after a blank one. Row 1 under the quantity names the
    device; `cols` are the sweep column and the value columns."""
    def __init__(self, rows, c):
        h = rows[0]
        w = 1
        while c + w < len(h) and h[c + w]:
            w += 1
        self.q, self.label, self.cols = h[c], rows[1][c].split()[0], list(range(c + 2, c + w))
        self.step = h[c + 3].split('=')[0].strip()


def blocks(rows):
    """Every data block right of the summary columns, in sheet order."""
    h = rows[0]
    return [Block(rows, c) for c in range(5, len(h)) if h[c] and not h[c - 1] and len(rows[1]) > c and rows[1][c]]


def left(rows, every_corner=False):
    """Rows of the summary table (the first, down to a blank or repeated
    `corners` cell) that carry a device label, as (label, row); only the
    first corner's unless every_corner."""
    out = []
    for r in rows[1:]:
        if len(r) < 4 or r[3] in ('', 'corners'):
            break
        if r[2].strip() and (every_corner or r[3] == rows[1][3]):
            out.append((r[2].split()[0], r))
    return out


def table(rows, cols, names=None):
    """The reference text: a header from row 0 (or names), then every row
    until the first column runs out."""
    out = [' '.join(n.replace(' ', '') for n in (names or [rows[0][c] for c in cols]))]
    for r in rows[1:]:
        if len(r) <= cols[0] or r[cols[0]] == '':
            break
        out.append(' '.join(r[c] if c < len(r) else '' for c in cols))
    return '\n'.join(out) + '\n'


def ctl_dc(tmpl):
    """The template with its .control block replaced by the sweep it runs:
    a `dc` line, or a `DC` line over `let` bounds stepped again by an
    `alter` of a `compose`d vector (the outer source of a nested .dc).
    A template whose own .DC card stays (or that has none) loses the block."""
    ctl = re.search(r'^\.control\b.*?^\.endc\b[^\n]*\n?', tmpl, re.S | re.M | re.I)
    if ctl:
        body = ctl.group()
        lets = dict(re.findall(r'^\s*let\s+(\w+)\s*=\s*(\S+)', body, re.M))
        dc = re.search(r'^\s*dc\s+(.*)$', body, re.M | re.I)
        card = ''
        if dc:
            args = [lets.get(t[2:], t) if t.startswith('$&') else t for t in dc.group(1).split()]
            m = re.search(r'compose\s+(\w+)\s+start=\s*(\S+)\s+stop=\s*(\S+)\s+step=\s*(\S+)', body)
            if m:
                args += [re.search(r'alter\s+(\w+)\s*=\s*%s\[' % m.group(1), body).group(1)] + list(m.groups()[1:])
            card = '.dc ' + ' '.join(args) + '\n'
        tmpl = tmpl.replace(body, card)
    return re.sub(r'"(\.\./)+', '"', tmpl)


def num(x):
    return '%g' % float(x)


def gf180(testing, out):
    reg = os.path.join(testing, 'regression')
    data = os.path.join(testing, '180MCU_SPICE_DATA')
    made = 0

    def deck(name, tmpl, vals, ref, quantity=None):
        nonlocal made
        text = re.sub(r'\{\{\s*(\w+)\s*\}\}', lambda m: str(vals[m.group(1)]), tmpl)
        if quantity:  # an operating-point device quantity: the .dc output alone does not carry it
            text = '* reference quantity: %s\n' % quantity + text
        open(os.path.join(out, name + '.sp'), 'w').write(text)
        open(os.path.join(out, name + '.sp.reference'), 'w').write(ref)
        made += 1

    def paired(what, rws, bl):
        if len(bl) != len(rws) or any(b.label != r[0] for b, r in zip(bl, rws)):
            print('cmcqa: gf180 %s: %d blocks for %d devices' % (what, len(bl), len(rws)), file=sys.stderr)
            return []
        return list(zip(rws, bl))

    def quarter(i, n, temps):  # upstream splits the rows into len(temps) equal runs, the remainder in the last
        return temps[min(i // max(n // len(temps), 1), len(temps) - 1)]

    # MOS Id (mos_iv_vgs, mos_iv_vbs) and Rds (mos_iv_vgs/device_netlists_Rds,
    # Rds = 1/gds: dId/dVds off the Id sweep).
    # The 6 V sheets hold |Gds| where the 3.3 V ones hold |Rds|.
    for fam, sub, qs, step, tag in (('mos_iv_vgs', 'Id', ('Id (A)', '-Id (A)'), 'vgs', 'vgs'),
                                    ('mos_iv_vbs', 'Id', ('Id (A)', '-Id (A)'), 'vbs', 'vbs'),
                                    ('mos_iv_vgs', 'Rds', ('|Rds (Ohm)|', '|Gds (S)|'), 'vgs', 'rds')):
        tdir = os.path.join(reg, fam, 'device_netlists_' + sub)
        for tf in sorted(os.listdir(tdir)):
            dev = tf[:-len('.spice')]
            rows = xlsx(os.path.join(data, 'MOS', dev + '.nl_out.xlsx'))
            pairs = paired(dev + ' ' + tag, left(rows), [b for b in blocks(rows) if b.q in qs and b.step == step])
            tmpl = ctl_dc(open(os.path.join(tdir, tf)).read())
            for i, ((_, r), b) in enumerate(pairs):
                ad, pd = float(r[0]) * 0.24, 2 * (float(r[0]) + 0.24)
                vals = dict(width=num(r[0]), length=num(r[1]), temp=quarter(i, len(pairs), (25, -40, 125)), i=i, AD=ad, PD=pd, AS=ad, PS=pd)
                deck('gf180_%s_%s_%d' % (tag, dev, i), tmpl, vals, table(rows, b.cols),
                     tag == 'rds' and ('|Rds| (Ohm) = 1/@mn[gds]' if 'Rds' in b.q else '|Gds| (S) = @mn[gds]'))

    # MOS CV (mos_cv): Cgc, Cgs and Cgd of each 3.3 V device. Upstream's Cgs
    # and Cgd templates hardcode W=200u L=0.28u nf=20 for every row; the
    # row's own geometry (nf from its label) replaces it here.
    rows = xlsx(os.path.join(reg, 'mos_cv', 'measured_data', '3p3_cv.nl_out.xlsx'))
    for kind in ('Cgc', 'Cgs', 'Cgd'):
        tdir = os.path.join(reg, 'mos_cv', 'device_netlists_' + kind)
        for tf in sorted(os.listdir(tdir)):
            dev = tf[:-len('_cv.spice')]
            pairs = paired(dev + ' ' + kind, [x for x in left(rows) if x[0] == dev], [b for b in blocks(rows) if b.label == dev and b.q == kind + ' (fF)'])
            tmpl = re.sub(r'W = \S+ L = \S+ nf=\S+', 'W = {{width}}u L = {{length}}u nf={{nf}}', ctl_dc(open(os.path.join(tdir, tf)).read()))
            for i, ((_, r), b) in enumerate(pairs):
                vals = dict(width=num(r[0]), length=num(r[1]), nf=re.search(r'nf=(\d+)', r[2]).group(1), i=i)
                deck('gf180_cv_%s_%s_%d' % (kind.lower(), dev, i), tmpl, vals, table(rows, b.cols), '%s (fF) = @mn[%s]*1e15' % (kind, 'cgb' if kind == 'Cgc' else kind.lower()))

    # BJT Ic(Vc) at stepped Ib (bjt_iv) and Ic, Ib against Vb at stepped Vc
    # (bjt_beta, both blocks side by side in one reference).
    bjt = os.path.join(data, 'BJT')
    for pol in ('npn', 'pnp'):
        rows = xlsx(os.path.join(bjt, 'bjt_%s_icvc_f.nl_out.xlsx' % pol))
        pairs = paired(pol + ' icvc', left(rows), blocks(rows))
        tmpl = ctl_dc(open(os.path.join(reg, 'bjt_iv', 'device_netlists', pol + '.spice')).read())
        for i, ((dev, _), b) in enumerate(pairs):
            deck('gf180_icvc_%s_%d' % (dev, i), tmpl, dict(device=dev, i=i, temp=quarter(i, len(pairs), (25, -40, 125, 175))), table(rows, b.cols))
        rows = xlsx(os.path.join(bjt, 'bjt_%s_beta_f.nl_out.xlsx' % pol))
        bl = blocks(rows)
        ic = paired(pol + ' beta Ic', left(rows), [b for b in bl if 'Ic' in b.q])
        ib = paired(pol + ' beta Ib', left(rows), [b for b in bl if 'Ib' in b.q])
        tmpl = ctl_dc(open(os.path.join(reg, 'bjt_beta', 'device_netlists', pol + '.spice')).read())
        for i, (((dev, _), c), (_, b)) in enumerate(zip(ic, ib)):
            cols = c.cols + b.cols[1:]
            names = [rows[0][c.cols[0]]] + ['Ic:' + rows[0][k] for k in c.cols[1:]] + ['Ib:' + rows[0][k] for k in b.cols[1:]]
            deck('gf180_beta_%s_%d' % (dev, i), tmpl, dict(device=dev, i=i, temp=quarter(i, len(ic), (25, -40, 125, 175))), table(rows, cols, names))

        # BJT junction capacitance (bjt_cj): one block per junction, device
        # and temperature (25, -40, 175 in turn), a column per corner.
        rows = xlsx(os.path.join(bjt, 'bjt_cv_%s.nl_out.xlsx' % pol))
        bl = blocks(rows)
        for k, b in enumerate(bl):
            _, junction, size = b.label.split('_', 2)
            t = os.path.join(reg, 'bjt_cj', 'device_netlists', '%s_%s.spice' % (pol, junction))
            if not os.path.isfile(t):
                continue
            dev, temp = 'v%s_%s' % (pol, size), quarter(k, len(bl), (25, -40, 175))
            tmpl = ctl_dc(open(t).read())
            for corner in ('typical', 'ff', 'ss'):
                col = next(c for c in b.cols if rows[0][c] == 'bjt_' + corner)
                deck('gf180_cj_%s_%s_%s_T%s' % (dev, junction, corner, str(temp).replace('-', 'm')), tmpl,
                     dict(device=dev, i=k, temp=temp, corner=corner, cv_sim='cv'), table(rows, [b.cols[0], col]),
                     'Cj (fF) = @q.xq1.q0[%s]*1e15' % {'EBJ': 'cpi', 'CBJ': 'cmu', 'CSJ': 'csub'}[junction])

    # Diode I(V) and C(V) (diode), temperatures -40, 25, 125, 175 in turn,
    # a column per corner.
    for dev in ('dnwps', 'dnwpw', 'np_3p3', 'np_6p0', 'nwp_3p3', 'nwp_6p0', 'pn_3p3', 'pn_6p0', 'sc_diode'):
        for kind in ('iv', 'cv'):
            rows = xlsx(os.path.join(reg, 'diode', '0_measured_data', '%s_%s.nl_out.xlsx' % (dev, kind)))
            pairs = paired(dev + ' ' + kind, left(rows), blocks(rows))
            tmpl = ctl_dc(open(os.path.join(reg, 'diode', 'device_netlists', kind + '.spice')).read())
            for i, ((_, r), b) in enumerate(pairs):
                for corner in ('typical', 'ff', 'ss'):
                    col = next(c for c in b.cols if rows[0][c].endswith('diode_' + corner))
                    vals = dict(device=dev, area=num(r[0]), pj=num(r[1]), i=i, temp=(-40, 25, 125, 175)[i % 4], Id_sim=kind, corner=corner)
                    deck('gf180_diode_%s_%s_%s_%d' % (dev, kind, corner, i), tmpl, vals, table(rows, [b.cols[0], col]),
                         'Cj (fF) = @dn[cd]*1e15' if kind == 'cv' else None)

    # MIM and MOS capacitors (mimcap_c, moscap_c): a .tran charging ramp
    # whose .meas is the capacitance. The label carries W x L; the first
    # row per device, size and corner is the 25 C one upstream reads.
    cap = os.path.join(data, 'Cap')
    for fam, xs in (('mimcap', ('mimcap_fc',)), ('moscap', ('moscap_cv_3p3', 'moscap_cv_6p0'))):
        tmpl = ctl_dc(open(os.path.join(reg, fam + '_c', 'device_netlists', fam + '.spice')).read())
        for x in xs:
            rows = xlsx(os.path.join(cap, x + '.nl_out.xlsx'))
            seen = set()
            for dev, r in left(rows, every_corner=True):
                w, l = re.search(r'\((\S+)u x(\S+)u', r[2]).groups()
                corner = r[3].split('_', 1)[1]
                if (dev, w, l, corner) in seen:
                    continue
                seen.add((dev, w, l, corner))
                deck('gf180_cap_%s_w%s_l%s_%s' % (dev, w, l, corner), tmpl, dict(device=dev, width=w, length=l, corner=corner),
                     'CV(fF)\n%s\n' % r[4])

    # Resistors (resistor_r): sheet resistance against W/L at 25 C (RES*a)
    # and against temperature (RES*b). One deck per file, corner and
    # temperature holds a copy per row: Vn drives r1_k (1 Mohm) into the
    # resistor, Rs = 1M*V(p_k)/(V(n)-V(p_k)) * w/l. Upstream's polarity list
    # is off by one in its wl half; p-type resistors take -3.3 V here, as in
    # its temp half.
    res = os.path.join(data, 'Resistor')
    for x in sorted(f for f in os.listdir(res) if re.match(r'RES\d+(a-wl|b-temp)-(?!nom)', f)):
        dev = x.split('-', 2)[2].split('.')[0]
        sign = '-' if dev.startswith(('pplus', 'ppolyf')) else ''
        term = '0 ' if not dev.startswith(('rm', 'tm')) else ''
        rows = xlsx(os.path.join(res, x))
        geo = []
        for _, r in left(rows):
            kv = dict(re.findall(r'(\w)=([-\d.]+)', r[2]))
            geo.append((kv['T'], kv['w'], kv['l'], r))
        for corner in ('typical', 'ff', 'ss'):
            col = rows[0].index('res_%s Rev9 ' % corner)
            for temp in dict.fromkeys(g[0] for g in geo):
                d = ['* GF180 %s sheet resistance, res_%s, T=%s C (generated by tests/suites/cmcqa/gen.py)' % (dev, corner, temp),
                     '.temp %s' % temp, '.options tnom=%s' % temp, 'vn n 0 dc %s3.3' % sign]
                ref = ['w l Rs(ohm/sq)']
                for k, (t, w, l, r) in enumerate(g for g in geo if g[0] == temp):
                    d += ['r1_%d n p_%d 1M' % (k, k), 'xrn_%d p_%d 0 %s%s r_width=%su r_length=%su' % (k, k, term, dev, w, l)]
                    ref.append('%s %s %s' % (w, l, r[col]))
                d += ['.op', '.include "design.ngspice"', '.lib "sm141064.ngspice" res_%s' % corner, '.end']
                deck('gf180_res_%s_%s_T%s' % (x.split('-')[0], corner, temp.replace('-', 'm')), '\n'.join(d) + '\n', {}, '\n'.join(ref) + '\n')
    print('cmcqa: gf180: %d decks' % made, file=sys.stderr)


def selftest():
    assert sweep('0.3,1.05,0.02')[-2:] == ['1.04', '1.05'] and len(sweep('1.0,-0.7,-0.05')) == 35
    assert pinval('V(coll)=0.5,1.0') == ('coll', '0.5,1.0')
    assert params('+ c10 = ( 9.074e-030 )\nTR=27.0 NSUBO=3.0E+23') == [('c10', '9.074e-030'), ('TR', '27.0'), ('NSUBO', '3.0E+23')]
    rows = [['W', 'L', '', 'c', 'x', '', 'Id (A)', 'bias', 'vds', 'vgs =1', 'vgs =2', '', 'Id (A)', 'bias', 'vds', 'vgs =1'],
            ['1', '2', 'n1\n(1u x2u)', 't', 'k', '', 'n1', 'lin', '0', '1e-6', '2e-6', '', 'n1', 'lin', '0', '3e-6'],
            ['', '', '', '', '', '', '', '', '0.1', '4e-6', '5e-6']]
    b = blocks(rows)
    assert [(x.q, x.label, x.step, x.cols) for x in b] == [('Id (A)', 'n1', 'vgs', [8, 9, 10]), ('Id (A)', 'n1', 'vgs', [14, 15])]
    assert left(rows) == [('n1', rows[1])]
    assert table(rows, b[0].cols) == 'vds vgs=1 vgs=2\n0 1e-6 2e-6\n0.1 4e-6 5e-6\n'
    assert ctl_dc('x\n.control\nlet a_min = 0\nlet a_max = 1\nlet a_step = 0.5\ncompose v start=1 stop=2 step=1\n'
                  'alter vg = v[0]\nDC va $&a_min $&a_max $&a_step\n.endc\n.lib "../../../m" t\n') == 'x\n.dc va 0 1 0.5 vg 1 2 1\n.lib "m" t\n'
    print('ok')


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    {'cmc': cmc, 'gf180': gf180, 'selftest': selftest}[cmd](*args)
