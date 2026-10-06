#!/usr/bin/env bash
# CircuitSim90/MCNC from Xyce_Regression (GPL-3.0-or-later, so fetched at a
# pinned commit, never vendored), converted from Xyce to ngspice dialect:
#   tests/suites/circuitsim90/fetch.sh DIR
# leaves DIR/{BJT,MOS2,MOS2_LARGE,MOS3}/<deck>.sp, all 43 decks. Conversion:
#   .print ANY ...            .save of every node or branch it names; the
#                             {v(x)+c} offsets, v(a,b) differences, vm/vdb
#                             forms and PRECISION=/WIDTH= are dropped
#   .options device temp=T    .temp T
#   .options timeint ...      method=gear and maxord=N kept; reltol=1e-3 is
#                             ngspice's default; abstol (an LTE tolerance in
#                             Xyce) and nlnearconv have no ngspice equivalent
#   .options nonlin/nonlin-tran/loca/linsol/dist
#                             dropped: Xyce's solver and continuation knobs.
#                             add20, add32 and dac need GMIN stepping (README);
#                             ngspice falls back to it on its own (gminsteps
#                             defaults to 10), so no option is added
#   + continuation lines      joined to their card first, so a dropped
#                             .options card (the homotopy setups) takes its
#                             continuation lines with it
#   duplicate instance names  pc_frame reuses m1 and c1 for every device;
#                             each repeat gets a unique _<n> suffix
#   floating nodes            smult20 (node 5592, capacitors only) and pc_frame
#                             (node 4512, gates and one capacitor) have no DC
#                             path to ground, so ngspice's operating point is
#                             singular; both get .options rshunt=1e12, which
#                             is how ngspice handles such nodes
# Skipped: nothing. Every deck converts faithfully; README.md lists the ones
# ngspice-45 cannot finish and why.
set -euo pipefail
D=$(mkdir -p "${1:?usage: fetch.sh DIR}" && cd "$1" && pwd)
SHA=bbde402756cdf542627ff7ea0056db130fcb005b   # Xyce/Xyce_Regression master, 2026-08-10
SRC=$D/src/Xyce_Regression
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$SHA" ]; then
  rm -rf "$SRC"
  git -c init.defaultBranch=main init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/Xyce/Xyce_Regression
  git -C "$SRC" sparse-checkout set Netlists/CircuitSim90
  git -C "$SRC" fetch -q --depth 1 --filter=blob:none origin "$SHA"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

python3 - "$SRC/Netlists/CircuitSim90" "$D" <<'PY'
import pathlib, re, sys
src, out = map(pathlib.Path, sys.argv[1:])
probe = re.compile(r'\b(v[mdbp]*|i)\(([^)]*)\)', re.I)
# Decks with nodes that have no DC path to ground (see the header).
extra = {'smult20': '.options rshunt=1e12', 'pc_frame': '.options rshunt=1e12'}
n = 0
for cir in sorted(src.glob('*/*.cir')):
    lines, card = [], 0
    for line in cir.read_text(errors='replace').replace('\r', '').split('\n'):
        if line.startswith('+') and card: lines[card] += ' ' + line[1:]   # join continuations
        else:
            if line.strip() and line.lstrip()[0] != '*': card = len(lines)
            lines.append(line)
    deck, seen, scope = [lines[0]] + ([extra[cir.stem]] if cir.stem in extra else []), set(), ''
    for no, line in enumerate(lines[1:], 2):
        w = line.split()
        key = w[0].lower() if w else ''
        if key == '.print':
            nodes = []
            for kind, args in probe.findall(line):
                for a in args.split(','):
                    p = f'{"i" if kind.lower() == "i" else "v"}({a.strip()})'
                    if p not in nodes: nodes.append(p)
            line = '.save ' + ' '.join(nodes)
        elif key in ('.options', '.option'):
            opts = [x.lower() for x in w[1:]]
            if opts[:1] == ['device']:
                line = ' '.join('.temp ' + x[5:] for x in opts if x.startswith('temp='))
            elif opts[:1] == ['timeint']:
                keep = [x for x in opts if x.startswith(('method=', 'maxord='))]
                line = '.options ' + ' '.join(keep) if keep else ''
            else:
                line = ''
        elif key == '.subckt':
            scope = w[1].lower()
        elif key == '.ends':
            scope = ''
        elif key and key[0] not in '.*+':
            if (scope, key) in seen: line = line.replace(w[0], f'{w[0]}_{no}', 1)
            seen.add((scope, key))
        deck.append(line)
    dst = out / cir.parent.name / (cir.stem + '.sp')
    dst.parent.mkdir(exist_ok=True)
    dst.write_text('\n'.join(deck))
    n += 1
print(f'{out}: {n} decks', file=sys.stderr)
PY
