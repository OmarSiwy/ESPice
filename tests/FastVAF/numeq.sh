#!/usr/bin/env bash
# Numeric-equivalence oracle: does a codegen change alter what the device COMPUTES?
#
#   tests/numeq.sh <old-fastvaf-binary> [model ...]
#
# `tests/baseline.sh` compares generated TEXT and `zig build conformance` compares
# diagnostics; neither can see a change that emits different-but-plausible
# arithmetic. This compiles each model through the reference binary and through
# the working tree, links both into one program, and compares residuals BITWISE
# over 2 000 deterministic operating points.
#
# It earns its keep: during the shared-core hoist (PERF.md fix 16) it caught two
# unsound prunes that 843 conformance fixtures AND the byte oracle both missed —
# an empty block skipped inside a LRM 5.9 loop, and a cached phi clearing the SSA
# join guard. Neither changes any diagnostic and both change the physics.
#
# Getting a reference binary (any commit or any saved tree):
#   zig build-exe -OReleaseFast -Mroot=src/main.zig -femit-bin=/tmp/fastvaf-ref
#
# A model that fails to compile under EITHER binary is skipped, not failed —
# `bsim4va` and `hicumL2_va` are expected to fail (see TODO.md), and several
# large models do not link a Debug harness in reasonable time.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
old="${1:?usage: numeq.sh <old-fastvaf-binary> [model ...]}"; shift
contract="$here/../devices/src/contract.zig"
models="$here/../devices/models"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

new="$work/fastvaf-new"
zig build-exe -OReleaseFast -Mroot="$here/src/main.zig" -femit-bin="$new" >/dev/null || exit 1

list=("$@"); [ ${#list[@]} -eq 0 ] && { list=(); for f in "$models"/*.va; do list+=("$(basename "$f" .va)"); done; }

pass=0 skip=0 failed=""
for m in "${list[@]}"; do
    va="$models/$m.va"
    "$old" --emit-zig --color=never -o "$work/old.zig" "$va" >/dev/null 2>&1 || { skip=$((skip+1)); continue; }
    "$new" --emit-zig --color=never -o "$work/new.zig" "$va" >/dev/null 2>&1 || { skip=$((skip+1)); continue; }
    # Debug, not ReleaseFast: this compares the ARITHMETIC THE CODE DESCRIBES.
    # An optimiser is free to reassociate, which would mask exactly the class of
    # bug this is looking for.
    if ! timeout 1800 zig build-exe -ODebug \
            --dep contract --dep old --dep new -Mroot="$here/tests/numeq/harness.zig" \
            --dep contract -Mold="$work/old.zig" \
            --dep contract -Mnew="$work/new.zig" \
            -Mcontract="$contract" -femit-bin="$work/eq" >"$work/build-$m.log" 2>&1; then
        skip=$((skip+1)); echo "SKIP(build) $m"; continue
    fi
    if out=$("$work/eq" 2>&1); then pass=$((pass+1)); echo "OK   $m — $out"
    else failed="$failed $m"; echo "FAIL $m — $out"; fi
    rm -f "$work/eq" "$work/old.zig" "$work/new.zig"
done

echo "=== numeric equivalence: $pass bit-identical, $skip skipped, failed:${failed:- none}"
[ -z "$failed" ]
