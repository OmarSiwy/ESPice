#!/usr/bin/env python3
"""CMC QA specs and the GF180MCU regression templates to ngspice-dialect decks.

  gen.py cmc QASPEC REFDIR OUT PREFIX NPN|NMOS|PMOS LEVEL
  gen.py gf180 TESTING OUT
  gen.py selftest

cmc: one deck per qaSpec test and temperature, OUT/PREFIX_<test>[_T<t>].sp,
with OUT/<deck>.reference holding that temperature's rows of the test's
.standard file (rows: biasList outer, biasSweep, then frequency). A deck
holds one copy of the device per biasList value (DC; the biasSweep pin of
every copy hangs off the swept source vsweep through a 0 V ammeter), or
per biasList value x biasSweep value x driven pin (AC: the copy's source
on the driven pin carries ac 1). A comment above each copy names its bias.
CMC sign conventions: I(p) = -i(v<p>_<k>), G(i,j) = Re(-i(v<i>_<k>)) of
the copy driven on j, C(i,j) = -Im(...)/w on the diagonal and +Im(...)/w
off it. Noise tests are skipped.

gf180: the mos_iv_vgs and mos_iv_vbs Id templates rendered for every W/L
row of the foundry xlsx (temperature 25, -40, 125 by thirds, as the
upstream models_regression.py does), .control replaced by its dc sweep.
The reference is the matching foundry Id block (|Id|, ngspice -i(Vds)).
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
    text = re.sub(r'[()+]', ' ', text)
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
    made = 0
    for t in tests:
        outs = t['outputs'].split()
        if any(o[0] in 'NV' for o in outs):
            continue  # ponytail: noise and thermal-node outputs; add .noise decks when the oracle wants them
        ref = os.path.join(refdir, t['name'] + '.standard')
        if not os.path.isfile(ref):
            print('cmcqa: no reference for', t['name'], file=sys.stderr)
            continue
        model = dict((k.lower(), (k, v)) for k, v in t['model'])
        model.pop('level', None); model.pop('type', None)
        card = '.model qamod %s level=%s\n' % (mtype.lower(), level) + ''.join('+ %s=%s\n' % kv for kv in model.values())
        sw_pin, sw = pinval(t['biasSweep']) if 'biasSweep' in t else (None, None)
        li_pin, li = pinval(t['biasList']) if 'biasList' in t else (None, '')
        lvals = li.split(',') if li_pin else [None]
        ac = outs[0][0] in 'GC'
        if ac:
            drive = list(dict.fromkeys(re.match(r'\w\(\w+,(\w+)\)', o).group(1) for o in outs))
            freq = t.get('freq') or 'lin 1 %r %r' % ((1 / (2 * math.pi),) * 2)  # CMC default: omega = 1
            copies = [(l, s, d) for l in lvals for s in (sweep(sw) if sw_pin else [None]) for d in drive]
        else:
            copies = [(l, None, None) for l in lvals]
        temps = t['temperature'].split()
        body = open(ref).read().strip().split('\n')
        head, rows = body[0], body[1:]
        if len(rows) % len(temps):
            print('cmcqa: %s: %d rows do not split over %d temperatures' % (t['name'], len(rows), len(temps)), file=sys.stderr)
            continue
        per = len(rows) // len(temps)
        for ti, temp in enumerate(temps):
            name = prefix + '_' + t['name'] + ('_T' + temp.replace('-', 'm').replace('.', 'p') if len(temps) > 1 else '')
            d = ['* CMC QA %s %s, T=%s C (generated by tests/suites/cmcqa/gen.py)' % (prefix, t['name'], temp),
                 '.temp %s' % temp]
            if sw_pin and not ac:
                d.append('vsweep sw 0 dc %s' % sw.split(',')[0])
            for k, (l, s, drv) in enumerate(copies):
                d.append('* copy %d: %s' % (k, ' '.join(x for x in (
                    l and 'V(%s)=%s' % (li_pin, l), s and 'V(%s)=%s' % (sw_pin, s), drv and 'ac on %s' % drv) if x) or 'bias only'))
                for p in pins:
                    if p in floating:
                        continue
                    if p == sw_pin and not ac:
                        d.append('v%s_%d %s_%d sw 0' % (p, k, p, k)); continue
                    v = l if p == li_pin else s if p == sw_pin else t['biases'].get(p, '0')
                    d.append('v%s_%d %s_%d 0 dc %s%s' % (p, k, p, k, v, ' ac 1' if p == drv else ''))
                d.append(' '.join(['%s%d' % (letter, k)] + ['%s_%d' % (p, k) for p in pins] + ['qamod'] + t['inst']))
            d.append(card.rstrip())
            if ac:
                d.append('.ac ' + freq)
            elif sw_pin:
                d.append('.dc vsweep ' + sw.replace(',', ' '))
            else:
                d.append('.op')
            d.append('.end')
            open(os.path.join(out, name + '.sp'), 'w').write('\n'.join(d) + '\n')
            open(os.path.join(out, name + '.sp.reference'), 'w').write('\n'.join([head] + rows[ti * per:(ti + 1) * per]) + '\n')
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


def blocks(header, prefix):
    """Start columns of each run of header cells that begin with prefix."""
    return [i for i, h in enumerate(header) if h.startswith(prefix) and not header[i - 1].startswith(prefix)]


def num(x):
    return '%g' % float(x)


def gf180(testing, out):
    reg = os.path.join(testing, 'regression')
    made = 0
    for fam, prefix in (('mos_iv_vgs', 'vgs ='), ('mos_iv_vbs', 'vbs =')):
        tdir = os.path.join(reg, fam, 'device_netlists_Id')
        for tf in sorted(os.listdir(tdir)):
            dev = tf[:-len('.spice')]
            rows = xlsx(os.path.join(testing, '180MCU_SPICE_DATA', 'MOS', dev + '.nl_out.xlsx'))
            dims = [r[:2] for r in rows[1:] if len(r) > 1 and r[1]]
            bl = blocks(rows[0], prefix)
            if len(bl) != 2 * len(dims):
                print('cmcqa: gf180 %s: %d blocks for %d sizes' % (dev, len(bl), len(dims)), file=sys.stderr)
                continue
            tmpl = open(os.path.join(tdir, tf)).read()
            ctl = re.search(r'^\.control\n(.*?)^\.endc\n', tmpl, re.S | re.M)
            dc = re.search(r'^dc .*$', ctl.group(1), re.M).group()
            tmpl = tmpl.replace(ctl.group(), '.' + dc + '\n')
            tmpl = re.sub(r'"\.\./\.\./\.\./', '"', tmpl)
            third = len(dims) // 3
            for i, (w, l) in enumerate(dims):
                temp = 25 if i < third else -40 if i < 2 * third else 125
                ad = float(w) * 0.24
                pd = 2 * (float(w) + 0.24)
                vals = dict(width=num(w), length=num(l), temp=temp, i=i, AD=ad, PD=pd, AS=ad, PS=pd)
                deck = re.sub(r'\{\{\s*(\w+)\s*\}\}', lambda m: str(vals[m.group(1)]), tmpl)
                name = 'gf180_%s_%s_%d' % (fam[-3:], dev, i)
                open(os.path.join(out, name + '.sp'), 'w').write(deck)
                c = bl[2 * i]
                width = 1
                while c + width < len(rows[0]) and rows[0][c + width].startswith(prefix):
                    width += 1
                ref = [' '.join(h.replace(' ', '') for h in rows[0][c - 1:c + width])]
                for r in rows[1:]:
                    if len(r) <= c or r[c - 1] == '':
                        break
                    ref.append(' '.join(r[c - 1:c + width]))
                open(os.path.join(out, name + '.sp.reference'), 'w').write('\n'.join(ref) + '\n')
                made += 1
    print('cmcqa: gf180: %d decks' % made, file=sys.stderr)


def selftest():
    assert sweep('0.3,1.05,0.02')[-2:] == ['1.04', '1.05'] and len(sweep('1.0,-0.7,-0.05')) == 35
    assert pinval('V(coll)=0.5,1.0') == ('coll', '0.5,1.0')
    assert params('+ c10 = ( 9.074e-030 )\nTR=27.0') == [('c10', '9.074e-030'), ('TR', '27.0')]
    assert blocks(['a', 'vgs =1', 'vgs =2', '', 'x', 'vgs =1'], 'vgs =') == [1, 5]
    print('ok')


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    {'cmc': cmc, 'gf180': gf180, 'selftest': selftest}[cmd](*args)
