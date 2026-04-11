#!/usr/bin/env bash
# run_benchmarks.sh — BigOSpice vs ngspice vs VACASK head-to-head benchmarks.
# Uses hyperfine for accurate wall-time measurement.
#
# Usage:
#   nix develop .#full --command bash scripts/run_benchmarks.sh [OPTIONS]
#   nix develop        --command bash scripts/run_benchmarks.sh [OPTIONS]
#
# Options:
#   --with-ngspice      Include ngspice in comparison
#   --with-vacask       Include VACASK in comparison
#   --with-all          Include all available simulators
#   --nruns N           Timing runs per circuit (default: 10)
#   --warmup N          Warmup runs before timing (default: 3)
#   --corpus DIR        Corpus directory (default: tests/fixtures/basic)
#   --circuit NAME      Run only circuits matching NAME substring
#   -h|--help           Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WITH_NGSPICE=0
WITH_VACASK=0
NRUNS=10
WARMUP=3
CORPUS="${ROOT}/tests/fixtures/basic"
FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-ngspice) WITH_NGSPICE=1; shift ;;
        --with-vacask)  WITH_VACASK=1;  shift ;;
        --with-all)     WITH_NGSPICE=1; WITH_VACASK=1; shift ;;
        --nruns)        NRUNS="$2";   shift 2 ;;
        --warmup)       WARMUP="$2";  shift 2 ;;
        --corpus)       CORPUS="$2";  shift 2 ;;
        --circuit)      FILTER="$2";  shift 2 ;;
        -h|--help)      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ── Build bigospice ──────────────────────────────────────────────────────────
echo "Building bigospice (release)..."
cargo build --release --quiet 2>&1
BIGS="${ROOT}/target/release/bigospice"
[[ -x "${BIGS}" ]] || { echo "ERROR: bigospice binary not found at ${BIGS}" >&2; exit 1; }

# ── Check optional simulators ───────────────────────────────────────────────
if [[ "${WITH_NGSPICE}" -eq 1 ]] && ! command -v ngspice &>/dev/null; then
    echo "WARNING: ngspice not found — disabling ngspice comparison" >&2
    WITH_NGSPICE=0
fi
if [[ "${WITH_VACASK}" -eq 1 ]] && ! command -v vacask &>/dev/null; then
    echo "WARNING: vacask not found — disabling vacask comparison" >&2
    WITH_VACASK=0
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
printf "%-32s %-14s" "Circuit" "BigOSpice"
[[ "${WITH_NGSPICE}" -eq 1 ]] && printf " %-14s %-9s" "ngspice" "vs-ng"
[[ "${WITH_VACASK}"  -eq 1 ]] && printf " %-14s %-9s" "VACASK"  "vs-va"
echo ""
printf '%.0s─' {1..80}; echo ""

# ── Benchmark each circuit ───────────────────────────────────────────────────
for sp in "${CORPUS}"/*.sp; do
    name="$(basename "${sp}")"
    [[ -n "${FILTER}" && "${name}" != *"${FILTER}"* ]] && continue

    sp_abs="$(realpath "${sp}")"
    hf_json="${TMP}/${name%.sp}.json"

    # ngspice needs a .control batch wrapper
    wrapper="${TMP}/${name%.sp}_ng.cir"
    printf '.include %s\n.control\nset filetype=ascii\nrun\nwrite %s all\n.endc\n' \
        "${sp_abs}" "${TMP}/${name%.sp}.raw" > "${wrapper}"

    # Build hyperfine args dynamically
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

    # Run silently — we parse the JSON for results
    hyperfine "${hf_args[@]}" >/dev/null 2>&1 || true

    # Parse JSON → print row, append ratios for geometric mean
    [[ -f "${hf_json}" ]] || { printf "%-32s SKIP\n" "${name}"; continue; }

    python3 - "${hf_json}" "${WITH_NGSPICE}" "${WITH_VACASK}" "${name}" \
              "${TMP}/ratios_ng.txt" "${TMP}/ratios_va.txt" <<'PYEOF'
import json, sys

fname, with_ng, with_va, name, ng_f, va_f = sys.argv[1:]
with_ng, with_va = int(with_ng), int(with_va)

try:
    d = json.load(open(fname))
    by_name = {r['command']: r['median'] for r in d['results']}
except Exception:
    print(f"{name:<32} ERROR reading results")
    sys.exit(0)

bigs = by_name.get('bigospice', 0.0)
ng   = by_name.get('ngspice',   0.0)
va   = by_name.get('vacask',    0.0)

# Sub-0.5ms timings are unreliable at low run counts — mark as N/A in speedup
MIN_T = 5e-4

def fmt(t):
    return f'{t * 1000:.2f}ms' if t > 0 else 'N/A'

def speedup(ref, base):
    if base < MIN_T or ref <= 0:
        return 'N/A', None
    return f'{ref / base:.2f}x', ref / base

ng_disp, ng_r = speedup(ng, bigs)
va_disp, va_r = speedup(va, bigs)

row = f"{name:<32} {fmt(bigs):<14}"
if with_ng:
    row += f" {fmt(ng):<14} {ng_disp:<9}"
if with_va:
    row += f" {fmt(va):<14} {va_disp:<9}"
print(row)

if with_ng and ng_r is not None:
    open(ng_f, 'a').write(f'{ng_r}\n')
if with_va and va_r is not None:
    open(va_f, 'a').write(f'{va_r}\n')
PYEOF
done

printf '%.0s─' {1..80}; echo ""; echo ""

# ── Geometric mean speedup summary ──────────────────────────────────────────
_geomean() {
    local ratios_file="$1" label="$2"
    [[ -f "${ratios_file}" ]] || return 0
    python3 - "${ratios_file}" "${label}" <<'PYEOF'
import sys, math
fname, label = sys.argv[1:]
ratios = [float(l) for l in open(fname) if l.strip()]
if not ratios:
    sys.exit(0)
gm  = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
mn  = min(ratios)
mx  = max(ratios)
print(f"BigOSpice vs {label}: geomean {gm:.2f}x faster  (range {mn:.2f}x – {mx:.2f}x, N={len(ratios)})")
PYEOF
}

[[ "${WITH_NGSPICE}" -eq 1 ]] && _geomean "${TMP}/ratios_ng.txt" "ngspice"
[[ "${WITH_VACASK}"  -eq 1 ]] && _geomean "${TMP}/ratios_va.txt" "VACASK"
