#!/usr/bin/env bash
# Generate expected golden properties for VF conformance fixtures.
# Runs each .v through verilator + zvf pipeline (via zig test) and captures output properties.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/conformance_v"
EXPECTED_DIR="$SCRIPT_DIR/expected_v"

cd "$SCRIPT_DIR/.."

passed=0
failed=0

for v_file in $(find "$FIXTURES_DIR" -name "*.v" | sort); do
    rel_path="${v_file#$FIXTURES_DIR/}"
    category=$(dirname "$rel_path")
    basename=$(basename "$rel_path" .v)
    out_dir="$EXPECTED_DIR/$category"
    mkdir -p "$out_dir"
    status_file="$out_dir/$basename.json"

    # Run through verilator to get JSON AST, then extract properties
    json_path="/tmp/zvf_conf_$basename.json"
    osdi_path="/tmp/zvf_conf_$basename.v"
    cp "$v_file" "$osdi_path"

    if verilator --json-only --json-only-output "$json_path" "$osdi_path" 2>/dev/null; then
        # Extract module name
        mod_name=$(python3 -c "
import json, sys
with open('$json_path') as f:
    data = json.load(f)
mods = data.get('modulesp', [])
if mods:
    print(mods[0].get('origName', ''))
" 2>/dev/null || echo "")

        # Count inputs/outputs
        counts=$(python3 -c "
import json
with open('$json_path') as f:
    data = json.load(f)
mods = data.get('modulesp', [])
if not mods: exit()
stmts = mods[0].get('stmtsp', [])
inputs = outputs = 0
has_always = False
is_sequential = False
for s in stmts:
    if s.get('type') == 'VAR':
        d = s.get('direction', '')
        dtype = s.get('dtypep', '')
        if d == 'INPUT': inputs += 1
        elif d == 'OUTPUT': outputs += 1
    elif s.get('type') == 'ALWAYS':
        has_always = True
        st = s.get('sentreep', [])
        for sent in st:
            for sense in sent.get('sensesp', []):
                e = sense.get('edgeType', '')
                if e in ('POS', 'NEG'):
                    is_sequential = True
print(f'{inputs},{outputs},{str(is_sequential).lower()}')
" 2>/dev/null || echo "0,0,false")

        input_count=$(echo "$counts" | cut -d, -f1)
        output_count=$(echo "$counts" | cut -d, -f2)
        is_sequential=$(echo "$counts" | cut -d, -f3)

        echo "  PASS  $rel_path (${input_count}in/${output_count}out, seq=$is_sequential)"
        cat > "$status_file" <<EOF
{
    "status": "compile_ok",
    "module_name": "$mod_name",
    "input_count": $input_count,
    "output_count": $output_count,
    "is_sequential": $is_sequential
}
EOF
        passed=$((passed + 1))
    else
        echo "  FAIL  $rel_path (verilator rejected)"
        cat > "$status_file" <<EOF
{
    "status": "verilator_error"
}
EOF
        failed=$((failed + 1))
    fi

    rm -f "$json_path" "$osdi_path"
done

echo ""
echo "=== Generation Results ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo "Total:  $((passed + failed))"
