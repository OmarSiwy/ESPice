#!/usr/bin/env bash
# Byte-identity oracle for codegen refactors.
#
# Most of the work in PERF.md's "Known-good next moves" is meant to change the
# compiler's SPEED, not its OUTPUT. `zig build conformance` proves the small
# fixtures still behave; this proves the 38 real foundry models still produce
# the identical byte stream — which is the only thing that catches a reordered
# emit, a lost back-patch, or a nondeterministic thread interleaving.
#
#   tests/baseline.sh gen           # record  -> /tmp/fastvaf-baseline/
#   tests/baseline.sh check         # compare against the recording
#   tests/baseline.sh check 20      # compare 20x (races show 1-in-N, not 1-in-1)
#
# The CLI is rebuilt ReleaseFast each run: a Debug build is ~10x slower and the
# timings in PERF.md are all ReleaseFast.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models="$here/../devices/models"
out="${BASELINE_DIR:-/tmp/fastvaf-baseline}"
# Per-invocation, so two agents/shells checking concurrently do not overwrite
# each other's binary mid-run.
exe="$(mktemp -u /tmp/fastvaf-oracle.XXXXXX)"
scratch="$(mktemp -d)"
# One trap for the whole script: bash REPLACES a trap rather than adding to it,
# so a second `trap ... EXIT` further down would silently leak the 8 MB binary.
trap 'rm -rf "$exe" "$exe.o" "$scratch"' EXIT

mode="${1:-check}"
runs="${2:-1}"

zig build-exe -OReleaseFast -Mroot="$here/src/main.zig" -femit-bin="$exe" >/dev/null

# A model that FAILS to compile is recorded as an empty `NAME.fail` marker
# rather than skipped, so the comparison catches a change that silently starts
# or stops rejecting a model. Two currently fail and both are expected:
#   hicumL2_va — uses `HSa` at :1758, declared nowhere in the file. Correct
#                rejection; the source is broken, not the compiler.
#   bsim4va    — `\`-continuation inside a string literal at :3658. Correct
#                rejection (E0138): LRM 2.7 requires a literal be "contained
#                on a single line" and Table 2-2 lists no \<newline> escape.
#                The continuation is SystemVerilog (IEEE 1800 5.9), which
#                Verilog-AMS never inherited from IEEE 1364-2005.
emit() { # emit <dest-dir>
    mkdir -p "$1"
    for va in "$models"/*.va; do
        n="$(basename "$va" .va)"
        "$exe" --emit-zig --color=never -o "$1/$n.zig" "$va" >/dev/null 2>&1 \
            || { rm -f "$1/$n.zig"; : > "$1/$n.fail"; }
    done
}

case "$mode" in
gen)
    rm -rf "$out"; emit "$out"
    echo "baseline: $(ls "$out" | wc -l) models, $(du -sh "$out" | cut -f1) in $out"
    ;;
check)
    tmp="$scratch"
    for i in $(seq 1 "$runs"); do
        emit "$tmp/$i"
        bad=0
        for f in "$out"/*; do
            cmp -s "$f" "$tmp/$i/$(basename "$f")" || { echo "DIFF run $i: $(basename "$f")"; bad=1; }
        done
        # A model that newly compiles (or newly fails) changes the file set, not
        # any single file's bytes — so compare the set too.
        diff <(ls "$out") <(ls "$tmp/$i") || bad=1
        [ "$bad" = 0 ] || exit 1
        rm -rf "$tmp/$i"
    done
    echo "byte-identical to baseline over $runs run(s)"
    ;;
*) echo "usage: baseline.sh [gen|check] [runs]" >&2; exit 2 ;;
esac
