#!/usr/bin/env bash
# Measures the nvptx device-kernel pipeline per model and per optimize mode.
# Splits the two costs that are currently fused in one build step:
#   emit  = zig build-obj  (frontend + LLVM IR emission)
#   ptx   = zig cc .ll     (NVPTX ISel + PTX printing)
# Usage: nix/ptxbench.sh <model>[:<cache-dir-hash>] ... -- <OptMode> ...
set -u
R=$(git rev-parse --show-toplevel)
GOMPUTE=$(ls -d "$R"/zig-pkg/gompute-*/src/device.zig)
CONTRACT="$R/src/devices/contract.zig"
KERNELS="$R/src/devices/kernels.zig"
KIR=${KIR:-/tmp/kir}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Locate a generated model .zig in the build cache by stem. The cache holds
# several copies per model across build configs, some stale and truncated —
# take the largest, which is the current full codegen.
find_model() {
  find "$R/.zig-cache/o" -maxdepth 2 -name "$1.zig" -printf '%s %p\n' |
    sort -rn | head -1 | cut -d' ' -f2
}

printf '%-14s %-12s %8s %8s %10s %10s\n' MODEL OPT EMIT_S PTX_S LL_LINES PTX_KB
for model in $MODELS; do
  src=$(find_model "$model")
  [ -z "$src" ] && { echo "$model: not in cache, skipping"; continue; }
  printf 'pub const %s = @import("%s");\n' "$model" "$model" > "$WORK/models.zig"

  for spec in $OPTS; do
    # "ROOT/MODULES" — the real build sets them independently (dev_opt reaches
    # only the root; models_mod keeps the host optimize).
    opt=${spec%%/*}
    mopt=${spec##*/}
    out="$WORK/$model.$opt-$mopt.ll"
    t0=$(date +%s.%N)
    if ! zig build-obj -fstrip "-O$opt" -target nvptx64-cuda -mcpu sm_89 \
        --dep gompute --dep models --dep contract \
        -Mroot="$KERNELS" \
        -Mgompute="$GOMPUTE" "-O$mopt" \
        --dep "$model" -Mmodels="$WORK/models.zig" "-O$mopt" \
        -Mcontract="$CONTRACT" "-O$mopt" \
        --dep contract "-M$model=$src" "-O$mopt" \
        -fno-emit-bin -femit-llvm-ir="$out" \
        --cache-dir "$WORK/zc" --global-cache-dir "$WORK/gc" \
        --name k >"$WORK/err.txt" 2>&1; then
      printf '%-14s %-12s %8s\n' "$model" "$spec" "EMIT-FAIL"
      tail -3 "$WORK/err.txt" | sed 's/^/    /'
      continue
    fi
    t1=$(date +%s.%N)

    # Same rewrite the real build does: NVPTX rejects aliases to kernels.
    "$KIR" "$out" "$WORK/fixed.ll" "$WORK/names.zig" >/dev/null 2>&1
    if ! zig cc -target nvptx64-cuda -mcpu=sm_89 -S -g0 \
        -Wno-unused-command-line-argument "$WORK/fixed.ll" -o "$WORK/$model.$opt-$mopt.ptx" \
        >"$WORK/err.txt" 2>&1; then
      printf '%-14s %-12s %8.1f %8s %10s\n' "$model" "$spec" \
        "$(echo "$t1-$t0" | bc)" "PTX-FAIL" "$(wc -l < "$out")"
      grep -m2 error "$WORK/err.txt" | sed 's/^/    /'
      continue
    fi
    t2=$(date +%s.%N)

    printf '%-14s %-12s %8.1f %8.1f %10s %10s\n' "$model" "$spec" \
      "$(echo "$t1-$t0" | bc)" "$(echo "$t2-$t1" | bc)" \
      "$(wc -l < "$out")" "$(( $(stat -c%s "$WORK/$model.$opt-$mopt.ptx") / 1024 ))"
  done
done
