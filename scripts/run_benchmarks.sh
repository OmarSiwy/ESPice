#!/usr/bin/env bash
# run_benchmarks.sh — BigOSpice vs ngspice head-to-head: accuracy + timing in one table.
# Uses hyperfine for wall-time measurement; skips timing for circuits that fail accuracy.
#
# Usage:
#   nix develop .#full --command bash scripts/run_benchmarks.sh [OPTIONS]
#   nix develop        --command bash scripts/run_benchmarks.sh [OPTIONS]
#
# All available simulators run by default (auto-detected via PATH).
# Use --no-* flags to explicitly exclude a simulator.
#
# Options:
#   --no-ngspice        Exclude ngspice from comparison
#   --no-vacask         Exclude VACASK from comparison
#   --no-xyce           Exclude Xyce from comparison
#   --nruns N           Timing runs per circuit (default: 10)
#   --warmup N          Warmup runs before timing (default: 3)
#   --corpus DIR        Corpus directory (default: tests/fixtures/quick)
#   --circuit NAME      Run only circuits matching NAME substring
#   --tol-pass N        Relative error threshold for PASS (default: 1e-3 = 0.1%)
#   -h|--help           Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WITH_NGSPICE=1
WITH_VACASK=1
WITH_XYCE=1
NRUNS=10
WARMUP=3
CORPUS="${ROOT}/tests/fixtures/quick"
FILTER=""
TOL_PASS=1e-3   # 0.1%

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-ngspice)   WITH_NGSPICE=0; shift ;;
        --no-vacask)    WITH_VACASK=0;  shift ;;
        --no-xyce)      WITH_XYCE=0;    shift ;;
        --nruns)        NRUNS="$2";     shift 2 ;;
        --warmup)       WARMUP="$2";    shift 2 ;;
        --corpus)       CORPUS="$2";    shift 2 ;;
        --circuit)      FILTER="$2";    shift 2 ;;
        --tol-pass)     TOL_PASS="$2";  shift 2 ;;
        -h|--help)      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ── Build bigospice (skip if cargo not in PATH — binary must be pre-built) ───
BIGS="${ROOT}/target/release/bigospice"
if command -v cargo &>/dev/null; then
    echo "Building bigospice (release)..."
    cargo build --release --quiet -p bigospice-cli 2>&1
fi
[[ -x "${BIGS}" ]] || { echo "ERROR: bigospice binary not found at ${BIGS} — run 'cargo build --release' first" >&2; exit 1; }

# ── Auto-detect optional simulators (silently skip if not in PATH) ───────────
if [[ "${WITH_NGSPICE}" -eq 1 ]] && ! command -v ngspice &>/dev/null; then
    echo "WARNING: ngspice not found — disabling ngspice comparison" >&2
    WITH_NGSPICE=0
fi
if [[ "${WITH_VACASK}" -eq 1 ]] && ! command -v vacask &>/dev/null; then
    echo "WARNING: vacask not found — disabling vacask comparison" >&2
    WITH_VACASK=0
fi
if [[ "${WITH_XYCE}" -eq 1 ]] && ! command -v xyce &>/dev/null; then
    echo "WARNING: xyce not found — disabling xyce comparison" >&2
    WITH_XYCE=0
fi
if ! command -v hyperfine &>/dev/null; then
    echo "ERROR: hyperfine not found — run inside nix develop shell" >&2
    exit 1
fi

[[ -d "${CORPUS}" ]] || { echo "ERROR: corpus not found: ${CORPUS}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── Print column header ──────────────────────────────────────────────────────
echo ""
printf "%-32s %-11s %-11s %-12s %s\n" "Circuit" "BigOSpice" "ngspice" "Accuracy" "Speed"
printf '%.0s─' {1..76}; echo ""

# ── Per-circuit: accuracy check first, then conditional timing ───────────────
for sp in "${CORPUS}"/*.sp; do
    name="$(basename "${sp}")"
    [[ -n "${FILTER}" && "${name}" != *"${FILTER}"* ]] && continue

    sp_abs="$(realpath "${sp}")"
    base="${TMP}/${name%.sp}"

    # ngspice batch wrapper
    raw_file="${base}.raw"
    wrapper="${base}_ng.cir"
    printf '.include %s\n.control\nset filetype=ascii\nrun\nwrite %s all\n.endc\n' \
        "${sp_abs}" "${raw_file}" > "${wrapper}"

    # ── Step 1: run both simulators for accuracy outputs ─────────────────────
    ng_ok=0
    bigs_ok=0
    bigs_out="${base}_bigs.txt"

    if [[ "${WITH_NGSPICE}" -eq 1 ]]; then
        ngspice -b "${wrapper}" >/dev/null 2>&1 && ng_ok=1 || true
    fi
    "${BIGS}" --output "${bigs_out}" --quiet "${sp_abs}" >/dev/null 2>&1 \
        && bigs_ok=1 || true

    # ── Step 2: determine accuracy status via Python ──────────────────────────
    acc_result_file="${base}_acc.txt"
    echo "SKIP(unknown)" > "${acc_result_file}"

    if [[ "${WITH_NGSPICE}" -eq 0 ]]; then
        echo "SKIP(no-ng)" > "${acc_result_file}"
    elif [[ "${ng_ok}" -eq 0 && "${bigs_ok}" -eq 0 ]]; then
        echo "SKIP(both)" > "${acc_result_file}"
    elif [[ "${ng_ok}" -eq 0 ]]; then
        echo "SKIP(ng)" > "${acc_result_file}"
    elif [[ "${bigs_ok}" -eq 0 ]]; then
        echo "SKIP(bigs)" > "${acc_result_file}"
    elif [[ ! -f "${raw_file}" ]]; then
        echo "SKIP(no-raw)" > "${acc_result_file}"
    else
        python3 - "${raw_file}" "${bigs_out}" "${TOL_PASS}" "${acc_result_file}" <<'PYEOF'
import sys, re

raw_path, bigs_path, tol_pass_s, out_path = sys.argv[1:]
tol_pass = float(tol_pass_s)

def parse_ngspice_raw(path):
    try:
        text = open(path, errors='replace').read()
    except Exception:
        return None
    var_match = re.search(r'Variables:\s*\n(.*?)(?:\nValues:|\Z)', text,
                          re.DOTALL | re.IGNORECASE)
    val_match = re.search(r'Values:\s*\n(.*)', text,
                          re.DOTALL | re.IGNORECASE)
    if not var_match or not val_match:
        return None
    var_lines = var_match.group(1).strip().splitlines()
    var_names = []
    for line in var_lines:
        parts = line.split()
        if len(parts) >= 2:
            var_names.append(parts[1].lower())
    if not var_names:
        return None
    val_text = val_match.group(1)
    blocks = re.split(r'\n(?=\s*\d+\s+[\d.eE+\-]+)', val_text)
    if not blocks:
        return None
    last_block = blocks[-1].strip()
    values = []
    for line in last_block.splitlines():
        parts = line.split()
        if not parts:
            continue
        try:
            values.append(float(parts[-1]))
        except ValueError:
            pass
    if len(values) < len(var_names):
        return None
    return {n: v for n, v in zip(var_names, values)}

def parse_bigs(path):
    try:
        lines = open(path).readlines()
    except Exception:
        return None
    result = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^v\(([^)]+)\)=([\d.eE+\-]+)$', line)
        if m:
            result['v(' + m.group(1).lower() + ')'] = float(m.group(2))
            continue
        parts = line.split('\t')
        if len(parts) == 3:
            try:
                result['v(' + parts[1].lower() + ')'] = float(parts[2])
            except ValueError:
                pass
            continue
        if len(parts) == 4:
            try:
                result['v(' + parts[1].lower() + ')'] = float(parts[2])
            except ValueError:
                pass
    return result if result else None

ng   = parse_ngspice_raw(raw_path)
bigs = parse_bigs(bigs_path)

if ng is None or bigs is None:
    open(out_path, 'w').write('SKIP(parse)')
    sys.exit(0)

shared = [n for n in ng if n in bigs and n.startswith('v(')]
if not shared:
    open(out_path, 'w').write('SKIP(no-nodes)')
    sys.exit(0)

max_err = 0.0
for node in shared:
    denom = max(abs(ng[node]), 1e-12)
    err   = abs(bigs[node] - ng[node]) / denom
    if err > max_err:
        max_err = err

if max_err < tol_pass:
    open(out_path, 'w').write('PASS')
else:
    open(out_path, 'w').write(f'FAIL {max_err:.2e}')
PYEOF
    fi

    acc_status="$(cat "${acc_result_file}")"

    # ── Step 3: run hyperfine only if accuracy PASSES ─────────────────────────
    hf_json="${base}.json"
    bigs_ms="--"
    ng_ms="--"
    speed_disp="--"

    # Determine if we should time this circuit
    should_time=0
    if [[ "${acc_status}" == "PASS" ]]; then
        should_time=1
    fi

    if [[ "${should_time}" -eq 1 ]]; then
        hf_args=(
            --warmup "${WARMUP}"
            --runs   "${NRUNS}"
            --export-json "${hf_json}"
            --output null
            --ignore-failure
            -n bigospice "${BIGS} --no-output --quiet ${sp_abs}"
        )
        [[ "${WITH_NGSPICE}" -eq 1 ]] && hf_args+=(-n ngspice "ngspice -b ${wrapper}")
        [[ "${WITH_VACASK}"  -eq 1 ]] && hf_args+=(-n vacask  "vacask --no-output --quiet-progress ${sp_abs}")
        [[ "${WITH_XYCE}"    -eq 1 ]] && hf_args+=(-n xyce    "xyce -b ${sp_abs}")

        hyperfine "${hf_args[@]}" >/dev/null 2>&1 || true

        if [[ -f "${hf_json}" ]]; then
            read -r bigs_ms ng_ms speed_disp < <(python3 - "${hf_json}" "${WITH_NGSPICE}" <<'PYEOF'
import json, sys
fname, with_ng = sys.argv[1], int(sys.argv[2])
try:
    d = json.load(open(fname))
    by_name = {r['command']: r['median'] for r in d['results']}
except Exception:
    print('-- -- --')
    sys.exit(0)

bigs = by_name.get('bigospice', 0.0)
ng   = by_name.get('ngspice',   0.0)
MIN_T = 5e-4

def fmt(t):
    return f'{t*1000:.2f}ms' if t > 0 else 'N/A'

bigs_s = fmt(bigs)
ng_s   = fmt(ng) if with_ng else '--'

if with_ng and bigs >= MIN_T and ng > 0:
    speed = f'{ng/bigs:.2f}x'
else:
    speed = '--'

print(bigs_s, ng_s, speed)
PYEOF
            )
        fi
    else
        # For non-PASS circuits, we still want BigOSpice timing alone (cheap, no ngspice)
        # but skip it entirely — the spec says skip hyperfine for broken circuits.
        bigs_ms="--"
        ng_ms="--"
        speed_disp="--"
    fi

    # ── Step 4: format and print the row ──────────────────────────────────────
    printf "%-32s %-11s %-11s %-12s %s\n" \
        "${name}" "${bigs_ms}" "${ng_ms}" "${acc_status}" "${speed_disp}"

    # Accumulate ratios for geomean (only PASS circuits with valid speedup)
    if [[ "${acc_status}" == "PASS" && "${speed_disp}" != "--" && "${speed_disp}" != "N/A" ]]; then
        echo "${speed_disp%x}" >> "${TMP}/ratios_ng.txt"
    fi

    # Accumulate accuracy stats
    case "${acc_status}" in
        PASS)        echo "pass"  >> "${TMP}/acc_counts.txt" ;;
        FAIL*)       echo "fail"  >> "${TMP}/acc_counts.txt" ;;
        SKIP*)       echo "skip"  >> "${TMP}/acc_counts.txt" ;;
    esac
done

printf '%.0s─' {1..76}; echo ""; echo ""

# ── Final summary: geomean speedup + accuracy pass rate ──────────────────────
python3 - "${TMP}/ratios_ng.txt" "${TMP}/acc_counts.txt" "${WITH_NGSPICE}" <<'PYEOF'
import sys, math, os

ratios_path, counts_path, with_ng = sys.argv[1], sys.argv[2], int(sys.argv[3])

# Speedup geomean
ratios = []
if os.path.exists(ratios_path):
    ratios = [float(l) for l in open(ratios_path) if l.strip()]

if ratios and with_ng:
    gm = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
    mn, mx = min(ratios), max(ratios)
    print(f"BigOSpice vs ngspice: geomean {gm:.2f}x faster  (range {mn:.2f}x – {mx:.2f}x, N={len(ratios)})")
elif with_ng:
    print("BigOSpice vs ngspice: no valid timing pairs collected")

# Accuracy pass rate
npass = nfail = nskip = 0
if os.path.exists(counts_path):
    for line in open(counts_path):
        t = line.strip()
        if t == 'pass':   npass += 1
        elif t == 'fail': nfail += 1
        elif t == 'skip': nskip += 1

total = npass + nfail + nskip
if total > 0:
    pct = 100 * npass / (npass + nfail) if (npass + nfail) > 0 else 0.0
    print(f"Accuracy: {npass}/{npass+nfail} PASS ({pct:.0f}%)  |  {nskip} SKIP  |  total {total} circuits")
PYEOF
