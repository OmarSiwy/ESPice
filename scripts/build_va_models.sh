#!/usr/bin/env bash
# build_va_models.sh — compile Verilog-A models to OSDI shared objects.
#
# Usage:
#   bash scripts/build_va_models.sh [--openvaf PATH] [--out-dir DIR]
#
# Prerequisites:
#   openvaf >= 23.x  (https://openvaf.semimod.de / https://github.com/pascalkuthe/OpenVAF)
#   The tool is GPL-3; we only consume its *output* (.osdi shared objects).
#   Install via: cargo install openvaf  OR  download a release binary.
#
# Output:
#   models/osdi/bsim4.osdi
#   models/osdi/diode.osdi
#   (and any other models listed in MODELS_DIR)
#
# All output files are named <stem>.osdi and placed in OUT_DIR.
# The integration tests in tests/integration/osdi_va_golden.rs look for
# these files relative to the workspace root.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default paths; override via environment or --flags below.
OPENVAF="${OPENVAF:-openvaf}"
MODELS_DIR="${WORKSPACE_ROOT}/models/va"
OUT_DIR="${WORKSPACE_ROOT}/models/osdi"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --openvaf)
            OPENVAF="$2"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --models-dir)
            MODELS_DIR="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! command -v "${OPENVAF}" &>/dev/null; then
    echo "openvaf not found, skipping VA compilation"
    echo "  (looked for '${OPENVAF}')"
    echo "  Install: cargo install openvaf  OR  download from https://openvaf.semimod.de"
    echo "  Or set OPENVAF=/path/to/openvaf and re-run this script."
    exit 0
fi

OPENVAF_VERSION="$("${OPENVAF}" --version 2>&1 | head -1)"
echo "openvaf: ${OPENVAF_VERSION}"

mkdir -p "${OUT_DIR}"

# ── Find .va model files ───────────────────────────────────────────────────────
# Look for bundled models in models/va/. If none are there yet, emit a
# clear message listing where to obtain them.
if [[ ! -d "${MODELS_DIR}" ]]; then
    echo "WARNING: models directory not found: ${MODELS_DIR}"
    echo "  Create ${MODELS_DIR} and place .va files there, or download:"
    echo "  - BSIM4: https://bsim.berkeley.edu/models/bsim4/"
    echo "  - Verilog-A diode: included in OpenVAF examples"
    echo "  Re-run this script after placing .va files in ${MODELS_DIR}."
    exit 0
fi

VA_FILES=("${MODELS_DIR}"/*.va)
if [[ "${#VA_FILES[@]}" -eq 0 ]] || [[ ! -f "${VA_FILES[0]}" ]]; then
    echo "WARNING: no .va files found in ${MODELS_DIR}."
    echo "  Place Verilog-A source files there and re-run."
    exit 0
fi

# ── Compile each model ────────────────────────────────────────────────────────
COMPILED=0
FAILED=0

for va_file in "${VA_FILES[@]}"; do
    stem="$(basename "${va_file}" .va)"
    out_file="${OUT_DIR}/${stem}.osdi"

    echo "Compiling ${va_file} -> ${out_file} ..."
    if "${OPENVAF}" "${va_file}" -o "${out_file}" 2>&1; then
        echo "  OK: ${out_file} ($(du -sh "${out_file}" 2>/dev/null | cut -f1))"
        COMPILED=$((COMPILED + 1))
    else
        echo "  FAILED: ${va_file}" >&2
        FAILED=$((FAILED + 1))
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Build complete: ${COMPILED} compiled, ${FAILED} failed."
echo "Output directory: ${OUT_DIR}"

if [[ "${FAILED}" -gt 0 ]]; then
    exit 1
fi

echo ""
echo "Run the OSDI integration tests with:"
echo "  nix develop -c cargo test --test integration osdi -- --include-ignored"
