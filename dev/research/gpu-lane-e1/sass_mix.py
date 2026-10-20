# Static SASS instruction mix of one function in `cuobjdump -sass` output.
# Usage: sass_mix.py FILE.sass FUNCTION
# Static counts: each instruction once, whatever its trip count, so read the
# classes as the shape of the code, not as dynamic work.
import re, sys, collections
text = open(sys.argv[1]).read()
m = re.search(r"Function : %s\n(.*?)(?=\n\s*Function : |\Z)" % re.escape(sys.argv[2]), text, re.S)
ops = collections.Counter(re.findall(r"/\*[0-9a-f]{4,}\*/\s+(?:@!?U?P\w+\s+)?([A-Z][A-Z0-9_]*)(?:\.[A-Z0-9_.]+)?", m.group(1)))
classes = {
    "fp64 fma/mul/add": ("DFMA", "DMUL", "DADD"),
    "fp64 cmp/minmax/setp": ("DSETP", "DMNMX"),
    "fp64 rcp/rsq seed (MUFU)": ("MUFU",),
    "fp32": ("FFMA", "FMUL", "FADD", "FSETP", "FMNMX", "FSEL"),
    "local ld/st (stack, spills)": ("LDL", "STL"),
    "global ld/st": ("LDG", "STG", "LD", "ST", "ATOMG", "RED"),
    "const/shared": ("LDC", "LDS", "STS", "ULDC"),
    "branch/call": ("BRA", "BRX", "CALL", "RET", "BSSY", "BSYNC", "EXIT", "JMP", "WARPSYNC"),
}
total = sum(ops.values())
print(f"{sys.argv[2]}: {total} instructions")
seen = set()
for name, codes in classes.items():
    n = sum(ops[c] for c in codes); seen |= set(codes)
    print(f"  {name:30s} {n:8d} {100 * n / total:5.1f}%")
rest = total - sum(ops[c] for c in seen)
print(f"  {'other (int, mov, sel, F2F...)':30s} {rest:8d} {100 * rest / total:5.1f}%")
print("  top:", ", ".join(f"{k} {v}" for k, v in ops.most_common(14)))
